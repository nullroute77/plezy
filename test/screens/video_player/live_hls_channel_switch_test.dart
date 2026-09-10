import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';
import 'package:plezy/screens/video_player/live_tv_session_state.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform oldPathProvider;
  late AppDatabase db;
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    await SettingsService.getInstance();
    root = await Directory.systemTemp.createTemp('live_switch_test');
    oldPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(root);
    await DownloadStorageService.instance.initialize(SettingsService.instance);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = oldPathProvider;
    await root.delete(recursive: true);
  });
  for (final mode in [
    'success',
    'failedLanding',
    'nativeFailure',
    'superseded',
    'supersededReady',
    'backwardsBeforeAdoption',
  ]) {
    testWidgets('HLS channel switch uses replacement session: $mode', (tester) async {
      final old = _Session('a', 1000);
      final next = _Session('b', 5000);
      final multi = testMultiServer(clients: [_Client(next)]);
      multi.provider.debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'srv-1', dvrKey: 'dvr')]);
      final offline = OfflineWatchSyncService(database: db, serverManager: multi.manager);
      final preferences = AccountPreferencesController();
      final hold = Completer<void>();
      Future<void> holdInitialization() => hold.future;
      PlaybackCoordinator.instance.registerMusicSession(stopAndDispose: holdInitialization);
      final key = GlobalKey<VideoPlayerScreenState>();
      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        testBody: () async {
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
                ChangeNotifierProvider(create: (_) => OfflineModeProvider(multi.manager)),
                ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
                ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offline),
                ChangeNotifierProvider<AccountPreferencesController>.value(value: preferences),
                Provider<AppDatabase>.value(value: db),
              ],
              child: MaterialApp(
                home: VideoPlayerScreen(
                  key: key,
                  metadata: testMediaItem(id: 'a', serverId: 'srv-1', backend: MediaBackend.jellyfin),
                  live: LiveTvSessionArgs(
                    channel: LiveTvChannel(key: 'a', serverId: 'srv-1'),
                    channels: [
                      LiveTvChannel(key: 'a', serverId: 'srv-1'),
                      LiveTvChannel(key: 'b', serverId: 'srv-1'),
                    ],
                    currentChannelIndex: 0,
                  ),
                ),
              ),
            ),
          );
          final state = key.currentState!;
          final live = state.debugLiveStateForTesting..adoptSession(old);
          live.timelineTimer = Timer.periodic(const Duration(seconds: 30), (_) {});
          final player = _Player(live, mode);
          state.player = player;
          if (mode == 'nativeFailure' || mode == 'backwardsBeforeAdoption') {
            await state.debugWirePlayerStreamsForTesting();
          }
          if (mode == 'backwardsBeforeAdoption') old.stopGate = Completer<void>();
          if (mode == 'supersededReady') player.openGate = Completer<void>();
          if (mode == 'superseded') next.gate = Completer<void>();
          var completed = false;
          final operation = state.debugSwitchLiveChannelForTesting(1).whenComplete(() => completed = true);
          await tester.pump();
          if (mode == 'superseded' || mode == 'supersededReady') {
            live.adoptSession(_Session('c', 9000));
            next.gate?.complete();
            player.openGate?.complete();
          }
          await tester.pump();
          if (mode == 'backwardsBeforeAdoption') {
            expect(player.opened, hasLength(1));
            expect(live.session, same(old));
            expect(live.timelineTimer, isNull);
            player.positionController.add(const Duration(seconds: 100));
            await tester.pump();
            player.positionController.add(const Duration(seconds: 90));
            await tester.pump();
            expect(old.historyRetired, isFalse);
            expect(next.historyRetired, isTrue);
            expect(live.captureBuffer?.startedAt, 1000);
            old.stopGate!.complete();
          }
          for (var i = 0; i < 400 && !completed; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
          }
          expect(completed, isTrue);
          await operation;
          if (mode == 'success') {
            expect(player.opened.single.uri, 'https://example.test/b/live.m3u8');
            expect(player.opened.single.headers?['User-Agent'], 'fixture-b');
            expect(old.prepares, 0);
            expect(next.prepares, 1);
            expect(old.stops, 1);
            expect(next.stops, 0);
            expect(live.session, same(next));
            expect(live.captureBuffer?.startedAt, 5000);
            expect(live.streamStartEpoch, 5000);
            expect(live.activeClockSourceId, 7);
          } else if (mode == 'backwardsBeforeAdoption') {
            expect(live.session, same(next));
            expect(live.captureBuffer, isNull);
            expect(live.activeClockSourceId, isNull);
          } else {
            expect(old.stops, 0);
            expect(next.stops, 1);
            expect(live.session, isNot(same(next)));
            if (mode == 'superseded') expect(player.opened, isEmpty);
            if (mode == 'failedLanding' || mode == 'nativeFailure') {
              expect(player.opened, hasLength(2));
              expect(old.historyRetired, isFalse);
              expect(live.timelineTimer, isNotNull);
              expect(player.opened.last.uri, 'https://example.test/a/live.m3u8');
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
          PlaybackCoordinator.instance.unregisterMusicSession(holdInitialization);
          hold.complete();
          await tester.pump();
          await tester.pump(const Duration(seconds: 20));
          var disposed = false;
          final disposal = player.dispose().whenComplete(() => disposed = true);
          for (var i = 0; i < 100 && !disposed; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
          }
          expect(disposed, isTrue);
          await disposal;
        },
      );
      offline.dispose();
      preferences.dispose();
    });
  }
}

class _Player extends PlayerNative {
  _Player(this.live, this.mode);
  final LiveTvSessionState live;
  final String mode;
  final opened = <Media>[];
  Completer<void>? openGate;
  @override
  Future<void> setProperty(String name, String value) async {}
  @override
  Future<int?> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    bool startLivePlaylistFromBeginning = false,
    Duration? seekPreRoll,
  }) async {
    opened.add(media);
    final sourceId = 6 + opened.length;
    if (mode == 'nativeFailure' && opened.length == 1) {
      errorController.add(const PlayerError('fixture end-file failure'));
      sourceFailedController.add(PlayerSourceFailed(sourceId));
      await Future<void>.value();
      return sourceId;
    }
    live.calibrateClockSource(
      PlayerSourceReady(
        sourceId: sourceId,
        position: mode == 'failedLanding' && opened.length == 1 ? const Duration(seconds: 90) : media.start!,
      ),
    );
    await openGate?.future;
    return sourceId;
  }
}

class _Session implements LiveTvPlaybackSession, LiveTvHlsTimeshiftSession {
  _Session(this.name, this.origin);
  final String name;
  final double origin;
  int prepares = 0;
  int stops = 0;
  Completer<void>? gate;
  Completer<void>? stopGate;
  @override
  bool historyRetired = false;
  @override
  CaptureBuffer? get captureBuffer =>
      historyRetired ? null : CaptureBuffer(startedAt: origin, seekStartSeconds: 0, seekEndSeconds: 100);
  @override
  LiveProgramInfo get program => LiveProgramInfo.none;
  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];
  @override
  Map<String, String> get playbackHeaders => {'User-Agent': 'fixture-$name'};
  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async =>
      'https://example.test/$name/master.m3u8';
  @override
  Future<LiveTvSeekRequest?> preparePlayback() async {
    prepares++;
    await gate?.future;
    return LiveTvSeekRequest(
      url: 'https://example.test/$name/live.m3u8',
      effectiveTargetEpoch: origin + 97,
      mediaStart: const Duration(seconds: 97),
      mediaEpochOrigin: origin,
    );
  }

  @override
  void invalidateHistory() => historyRetired = true;
  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async {
    if (state == 'stopped') {
      stops++;
      await stopGate?.future;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements MediaServerClient {
  _Client(this.session);
  final _Session session;
  @override
  ServerId get serverId => ServerId('srv-1');
  @override
  String get serverName => 'Fixture';
  @override
  MediaBackend get backend => MediaBackend.jellyfin;
  @override
  ServerCapabilities get capabilities => const ServerCapabilities(liveTv: true);
  @override
  LiveTvSupport get liveTv => _Support(session);
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Support implements LiveTvSupport {
  _Support(this.session);
  final _Session session;
  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async => session;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
