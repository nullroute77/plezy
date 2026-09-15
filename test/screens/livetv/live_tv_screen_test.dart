import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/models/media_grab_operation.dart';
import 'package:plezy/models/media_subscription.dart';
import 'package:plezy/screens/livetv/tv_guide_program_info.dart';
import 'package:plezy/theme/mono_tokens.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/guide_search_sheet.dart';
import 'package:plezy/screens/livetv/live_tv_screen.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('en');
    if (const String.fromEnvironment('GUIDE_SCREENSHOT_DIR').isNotEmpty) {
      await (FontLoader('GuidePreview')..addFont(rootBundle.load('assets/go-noto-current-regular.ttf'))).load();
      await (FontLoader(
        'packages/material_symbols_icons/MaterialSymbolsRounded',
      )..addFont(rootBundle.load('packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf'))).load();
    }
  });

  setUp(() async {
    resetSharedPreferencesForTest(initialAsync: {'live_tv_default_favorites': true});
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
  });

  for (final appearance in [(dark: false, oled: false), (dark: true, oled: false), (dark: true, oled: true)]) {
    testWidgets(
      'TV page keeps tabs above information and six rows with a date picker beside plain time labels ($appearance)',
      (tester) async {
        TvDetectionService.debugSetAppleTVOverride(true);
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          TvDetectionService.debugSetAppleTVOverride(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final harness = await _pumpLiveTvScreen(
          tester,
          channelKeys: List.generate(8, (i) => 'channel-$i'),
          withDvr: true,
          withPrograms: true,
          theme: monoTheme(dark: appearance.dark, oled: appearance.oled),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          harness.dispose();
        });
        harness.liveTv.favorites.complete([]);
        await tester.pumpAndSettle();
        final info = find.byType(TvGuideProgramInfo);
        final appBar = find.byType(AppBar);
        for (final label in [t.liveTv.guide, t.liveTv.whatsOn, t.liveTv.recordings]) {
          final tab = find.descendant(of: appBar, matching: find.text(label));
          expect(tab.hitTestable(), findsOneWidget);
          expect(tester.getBottomLeft(tab).dy, lessThan(tester.getTopLeft(info).dy));
        }
        final grid = find.byKey(const ValueKey('guide-timeline-grid'));
        final gridRect = tester.getRect(grid);
        for (var i = 0; i < 6; i++) {
          final channel = find.descendant(of: grid, matching: find.text('Unique Channel channel-$i'));
          expect(gridRect.contains(tester.getCenter(channel)), isTrue);
        }
        expect(find.descendant(of: grid, matching: find.text('Unique Channel channel-6')).hitTestable(), findsNothing);
        final slots = find.byWidgetPredicate((w) => w is Container && w.key.toString().contains('guide-time-slot-'));
        final first = tester.widget<Container>(slots.first);
        final colors = tokens(tester.element(slots.first));
        expect(first.decoration, isNull);
        expect(first.color, isNull);
        expect(tester.getTopLeft(slots.at(1)).dx - tester.getTopLeft(slots.first).dx, 240);
        final today = find.text(t.liveTv.today);
        expect(tester.getRect(today).right, lessThan(tester.getRect(slots.first).left));
        expect(tester.getCenter(today).dy, closeTo(tester.getCenter(slots.first).dy, 1));
        final luminances = [
          colors.text.computeLuminance(),
          Theme.of(tester.element(slots.first)).scaffoldBackgroundColor.computeLuminance(),
        ]..sort();
        expect((luminances.last + 0.05) / (luminances.first + 0.05), greaterThanOrEqualTo(4.5));
        expect(find.descendant(of: info, matching: find.text('S1E9 Heat Day')), findsOneWidget);
        const screenshotDir = String.fromEnvironment('GUIDE_SCREENSHOT_DIR');
        if (screenshotDir.isNotEmpty) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('live-tv-capture')));
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            try {
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              Directory(screenshotDir).createSync(recursive: true);
              final name = appearance.oled
                  ? 'oled'
                  : appearance.dark
                  ? 'dark'
                  : 'light';
              File('$screenshotDir/tv-full-page-$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final staleFavorite in [false, true]) {
    testWidgets('empty or stale favorites keep all channels visible (stale: $staleFavorite)', (tester) async {
      final harness = await _pumpLiveTvScreen(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        harness.dispose();
      });
      harness.liveTv.favorites.complete([
        if (staleFavorite) FavoriteChannel(id: 'channel-gone', source: 'server://server-a/provider-a'),
      ]);
      await tester.pumpAndSettle();
      final guide = tester.widget<GuideTab>(find.byType(GuideTab));
      expect(guide.channels.map((c) => c.key), ['channel-a']);
      expect(guide.favoriteChannels, isEmpty);
      expect(find.byTooltip(t.liveTv.favorites), findsNothing);
      expect(find.text(t.liveTv.favorites), findsNothing);
    });
  }

  testWidgets('refresh keeps the favorites group populated while favorites reload', (tester) async {
    final harness = await _pumpLiveTvScreen(tester, channelKeys: const ['channel-a', 'channel-b']);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    final favorite = FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a');
    harness.liveTv.favorites.complete([favorite]);
    await tester.pumpAndSettle();

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
    expect(tester.widget<GuideTab>(find.byType(GuideTab)).favoriteChannels.map((c) => c.key), ['channel-a']);

    await tester.tap(find.byIcon(Symbols.refresh_rounded));
    await tester.pumpAndSettle();

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
    expect(tester.widget<GuideTab>(find.byType(GuideTab)).favoriteChannels.map((c) => c.key), ['channel-a']);

    harness.liveTv.favorites.complete([favorite]);
    await tester.pumpAndSettle();

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
    expect(tester.widget<GuideTab>(find.byType(GuideTab)).favoriteChannels.map((c) => c.key), ['channel-a']);
  });

  testWidgets('guide search can reach a channel below the favorites group', (tester) async {
    final harness = await _pumpLiveTvScreen(tester, channelKeys: const ['channel-a', 'channel-b']);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    harness.liveTv.favorites.complete([FavoriteChannel(id: 'channel-a', source: 'server://server-a/provider-a')]);
    await tester.pumpAndSettle();
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
    expect(tester.widget<GuideTab>(find.byType(GuideTab)).favoriteChannels.map((c) => c.key), ['channel-a']);

    await tester.tap(find.byIcon(Symbols.search_rounded));
    await tester.pumpAndSettle();

    // Search includes favorites and the rest of the lineup.
    final sheet = find.byType(GuideSearchSheet);
    expect(find.descendant(of: sheet, matching: find.text('Unique Channel A')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Unique Channel channel-b')), findsOneWidget);

    await tester.tap(find.descendant(of: sheet, matching: find.text('Unique Channel channel-b')));
    await tester.pumpAndSettle();

    // Both groups remain available after the jump.
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a', 'channel-b']);
  });

  testWidgets('favorite read failure preserves raw Guide channels', (tester) async {
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });

    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);

    harness.liveTv.favorites.completeError(StateError('favorite read failed'));
    await tester.pumpAndSettle();

    expect(find.byTooltip(t.liveTv.favorites), findsNothing);
    expect(_guideChannels(tester).map((channel) => channel.key), ['channel-a']);
  });
  testWidgets('favorite failure keeps favorites loaded from healthy stores', (tester) async {
    final failedLiveTv = _FakeLiveTvSupport(serverId: 'server-a', storeKey: 'store-a');
    final healthyLiveTv = _FakeLiveTvSupport(serverId: 'server-b', storeKey: 'store-b');
    final failedClient = _FakeMediaServerClient(failedLiveTv, serverId: ServerId('server-a'));
    final healthyClient = _FakeMediaServerClient(healthyLiveTv, serverId: ServerId('server-b'));
    final manager = MultiServerManager()
      ..debugRegisterClientForTesting(failedClient)
      ..debugRegisterClientForTesting(healthyClient);
    final provider = testMultiServerProvider(manager);
    provider.debugSetLiveTvServersForTesting([
      LiveTvServerInfo(serverId: 'server-a', dvrKey: 'dvr-a', lineup: 'provider-a'),
      LiveTvServerInfo(serverId: 'server-b', dvrKey: 'dvr-b', lineup: 'provider-b'),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      provider.dispose();
      manager.dispose();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(theme: monoTheme(dark: true), home: const LiveTvScreen()),
          ),
        ),
      ),
    );
    failedLiveTv.favorites.completeError(StateError('favorite read failed'));
    healthyLiveTv.favorites.complete([FavoriteChannel(id: 'channel-server-b', source: 'server://server-b/provider-b')]);
    await tester.pumpAndSettle();

    final guide = tester.widget<GuideTab>(find.byType(GuideTab));
    final healthyChannel = guide.channels.singleWhere((channel) => channel.serverId == 'server-b');
    expect(guide.isFavoriteChannel!(healthyChannel), isTrue);
    expect(guide.channels.map((channel) => channel.serverId), ['server-a', 'server-b']);
    expect(guide.favoriteChannels.map((channel) => channel.serverId), ['server-b']);
  });

  testWidgets('favorite write failure keeps optimistic state, shows feedback, and leaves the queue usable', (
    tester,
  ) async {
    final harness = await _pumpLiveTvScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    });
    harness.liveTv.writeFailures.add(StateError('favorite write failed'));
    harness.liveTv.favorites.complete(const []);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Unique Channel A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    var guide = tester.widget<GuideTab>(find.byType(GuideTab));
    expect(guide.isFavoriteChannel!(guide.channels.single), isTrue);
    expect(find.text(t.liveTv.favoritesUpdateFailed), findsOneWidget);
    expect(harness.liveTv.writes.map((write) => write.map((favorite) => favorite.id).toList()), [
      ['channel-a'],
    ]);

    await tester.longPress(find.text('Unique Channel A'));
    await tester.pumpAndSettle();

    guide = tester.widget<GuideTab>(find.byType(GuideTab));
    expect(guide.isFavoriteChannel!(guide.channels.single), isFalse);
    expect(harness.liveTv.writes.map((write) => write.map((favorite) => favorite.id).toList()), [
      ['channel-a'],
      <String>[],
    ]);
  });
}

List<LiveTvChannel> _guideChannels(WidgetTester tester) => tester.widget<GuideTab>(find.byType(GuideTab)).channels;

Future<_LiveTvHarness> _pumpLiveTvScreen(
  WidgetTester tester, {
  List<String>? channelKeys,
  bool withDvr = false,
  bool withPrograms = false,
  ThemeData? theme,
}) async {
  final liveTv = _FakeLiveTvSupport(
    channelKeys: channelKeys,
    dvr: withDvr ? _FakeDvrSupport() : null,
    withPrograms: withPrograms,
  );
  final client = _FakeMediaServerClient(liveTv);
  final manager = MultiServerManager()..debugRegisterClientForTesting(client);
  final provider = testMultiServerProvider(manager);
  provider.debugSetLiveTvServersForTesting([
    LiveTvServerInfo(serverId: client.serverId.value, dvrKey: 'dvr-a', lineup: 'provider-a'),
  ]);
  final harness = _LiveTvHarness(manager: manager, provider: provider, liveTv: liveTv);

  await tester.pumpWidget(
    TranslationProvider(
      child: InputModeTracker(
        child: ChangeNotifierProvider<MultiServerProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: (theme ?? monoTheme(dark: true)).copyWith(
              textTheme: const String.fromEnvironment('GUIDE_SCREENSHOT_DIR').isEmpty
                  ? null
                  : (theme ?? monoTheme(dark: true)).textTheme.apply(fontFamily: 'GuidePreview'),
            ),
            home: const RepaintBoundary(key: ValueKey('live-tv-capture'), child: LiveTvScreen()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

class _LiveTvHarness {
  const _LiveTvHarness({required this.manager, required this.provider, required this.liveTv});

  final MultiServerManager manager;
  final MultiServerProvider provider;
  final _FakeLiveTvSupport liveTv;

  void dispose() {
    provider.dispose();
    manager.dispose();
  }
}

class _FakeMediaServerClient implements MediaServerClient {
  _FakeMediaServerClient(this.liveTv, {ServerId? serverId}) : serverId = serverId ?? ServerId('server-a');

  @override
  final LiveTvSupport liveTv;

  @override
  final ServerId serverId;

  @override
  String? get serverName => 'Server ${serverId.value}';

  @override
  MediaBackend get backend => MediaBackend.jellyfin;

  @override
  ServerCapabilities get capabilities => ServerCapabilities(liveTv: true, liveTvDvr: liveTv.dvr != null);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLiveTvSupport implements LiveTvSupport {
  _FakeLiveTvSupport({
    this.serverId = 'server-a',
    this.storeKey = 'test-store',
    this.dvr,
    this.withPrograms = false,
    List<String>? channelKeys,
  }) : channelKeys = channelKeys ?? [serverId == 'server-a' ? 'channel-a' : 'channel-$serverId'];

  final String serverId;
  final String storeKey;
  final List<String> channelKeys;
  final List<Completer<List<FavoriteChannel>>> _favoriteRequests = [];
  int _servedFavoriteRequests = 0;

  Completer<List<FavoriteChannel>> get favorites {
    if (_favoriteRequests.length > _servedFavoriteRequests) {
      return _favoriteRequests[_servedFavoriteRequests];
    }
    if (_servedFavoriteRequests > 0 && !_favoriteRequests[_servedFavoriteRequests - 1].isCompleted) {
      return _favoriteRequests[_servedFavoriteRequests - 1];
    }
    final request = Completer<List<FavoriteChannel>>();
    _favoriteRequests.add(request);
    return request;
  }

  @override
  final LiveTvDvrSupport? dvr;

  final bool withPrograms;

  @override
  String get favoriteStoreKey => storeKey;

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => 'server://$serverId/${lineup ?? 'default'}';

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) async => [
    for (final key in channelKeys)
      LiveTvChannel(
        key: key,
        title: key == 'channel-a' ? 'Unique Channel A' : 'Unique Channel $key',
        serverId: serverId,
      ),
  ];

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async => [
    if (withPrograms)
      for (var i = 0; i < channelKeys.length; i++)
        LiveTvProgram(
          ratingKey: 'program-$i',
          title: i == 0 ? 'Flavortown Food Fight' : 'Evening program ${i + 1}',
          programTitle: i == 0 ? 'Flavortown Food Fight' : 'Evening program ${i + 1}',
          episodeTitle: i == 0 ? 'Heat Day' : null,
          parentIndex: i == 0 ? 1 : null,
          index: i == 0 ? 9 : null,
          summary:
              'The chefs turn up the heat in a summer cooking challenge, with a surprise ingredient and a race against the clock.',
          contentRating: 'TV-PG',
          isNew: i == 0,
          live: i == 1,
          beginsAt: from!.millisecondsSinceEpoch ~/ 1000,
          endsAt: from.add(const Duration(minutes: 90)).millisecondsSinceEpoch ~/ 1000,
          channelIdentifier: channelKeys[i],
          serverId: serverId,
        ),
  ];

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) {
    if (_favoriteRequests.length == _servedFavoriteRequests) {
      _favoriteRequests.add(Completer<List<FavoriteChannel>>());
    }
    return _favoriteRequests[_servedFavoriteRequests++].future;
  }

  final List<Object> writeFailures = [];
  final List<List<FavoriteChannel>> writes = [];

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
    writes.add(List.of(channels));
    if (writeFailures.isNotEmpty) throw writeFailures.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDvrSupport implements LiveTvDvrSupport {
  @override
  bool get supportsRuleProcessing => false;

  @override
  Future<List<MediaGrabOperation>> fetchScheduledRecordings() async => [];

  @override
  Future<List<MediaSubscription>> fetchRecordingRules({bool includeGrabs = true, bool includeStorage = true}) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
