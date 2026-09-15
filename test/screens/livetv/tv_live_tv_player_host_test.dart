import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/screens/livetv/tv_live_tv_player_host.dart';
import 'package:plezy/screens/livetv/tv_live_tv_playback_scope.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/tv_backdrop_scrim.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/pump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(true);
  });

  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  testWidgets('TV guide keeps the same guide and player through fullscreen and Back', (tester) async {
    final manager = MultiServerManager();
    addTearDown(manager.dispose);
    final initialize = Completer<bool>();
    final calls = <MethodCall>[];
    var shown = 0;
    final guideKey = GlobalKey<_GuideState>();
    final channel = LiveTvChannel(key: 'one', title: 'One');
    final live = LiveTvSessionArgs(channel: channel, channels: [channel], currentChannelIndex: 0);
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) {
        calls.add(call);
        return call.method == 'initialize' ? initialize.future : Future<Object?>.value(null);
      },
      testBody: () async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
              ChangeNotifierProvider(create: (_) => OfflineModeProvider(manager)),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: TvLiveTvPlayerHost(
                  onGuideShown: () {
                    shown++;
                    guideKey.currentState?.focus.requestFocus();
                  },
                  builder: (_) => _Guide(key: guideKey),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(VideoPlayerScreen), findsNothing);
        expect(find.byType(TvBackdropScrim), findsNothing);
        final guideState = guideKey.currentState!;
        guideState.mark = 42;
        await TvLiveTvPlaybackScope.maybeOf(guideKey.currentContext!)!.play(testMediaItem(), live);
        await tester.pump();
        await tester.pump();
        await pumpUntil(tester, () => calls.any((call) => call.method == 'initialize'));
        final playerState = tester.state<VideoPlayerScreenState>(find.byType(VideoPlayerScreen));
        expect(guideKey.currentState, same(guideState));
        expect(find.text('Guide'), findsNothing);

        // Back is a real platform pop attempt, not an invocation of the host's
        // callback: a single event must reveal the guide without closing it.
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump();
        expect(find.text('Guide'), findsOneWidget);
        expect(find.byType(TvBackdropScrim), findsOneWidget);
        expect(tester.state<VideoPlayerScreenState>(find.byType(VideoPlayerScreen)), same(playerState));
        expect(guideKey.currentState, same(guideState));
        expect(guideState.mark, 42);
        expect(shown, 1);
        expect(guideState.focus.hasFocus, isTrue);
        expect(calls.where((call) => call.method == 'initialize'), hasLength(1));
        expect(calls.where((call) => ['dispose', 'stop', 'pause'].contains(call.method)), isEmpty);

        await TvLiveTvPlaybackScope.maybeOf(guideKey.currentContext!)!.play(testMediaItem(), live);
        await tester.pump();
        await tester.pump();
        expect(tester.state<VideoPlayerScreenState>(find.byType(VideoPlayerScreen)), same(playerState));
        expect(find.text('Guide'), findsNothing);
        expect(guideKey.currentState, same(guideState));
        expect(tester.takeException(), isNull);

        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump();
        initialize.complete(false);
        await tester.binding.handlePopRoute();
        await pumpUntil(tester, () => find.byType(VideoPlayerScreen).evaluate().isEmpty);
        await tester.pump();
        await tester.pump();
        expect(find.byType(VideoPlayerScreen), findsNothing);
        expect(find.byType(TvBackdropScrim), findsNothing);
        expect(guideKey.currentState, same(guideState));
        expect(guideState.mark, 42);
        expect(find.text('Guide'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

class _Guide extends StatefulWidget {
  const _Guide({super.key});

  @override
  State<_Guide> createState() => _GuideState();
}

class _GuideState extends State<_Guide> {
  int mark = 0;
  final focus = FocusNode();

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    child: const Center(child: Text('Guide')),
  );
}
