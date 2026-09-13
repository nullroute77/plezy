import 'dart:async';

import 'package:clock/clock.dart';
import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/whats_on_tab.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/http_fixtures.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));
  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  for (final dialect in MediaBrowserDialect.values) {
    testWidgets('${dialect.name} loads current programs and preserves popup metadata', (tester) async {
      final now = DateTime.now();
      final requests = <Uri>[];
      final client = testJellyfinClient(
        connection: testJellyfinConnection(dialect: dialect),
        handler: (request) async {
          requests.add(request.url);
          return jsonResponse({
            'Items': [
              _program('Current show', now.subtract(const Duration(minutes: 20)), now.add(const Duration(minutes: 10))),
              _program('Ended show', now.subtract(const Duration(hours: 1)), now),
              _program('Future show', now.add(const Duration(minutes: 10)), now.add(const Duration(hours: 1))),
              {'Id': 'undated', 'Name': 'Unknown timing'},
            ],
          });
        },
      );
      await withClock(Clock.fixed(now), () async {
        await _pump(tester, [client]);
        expect(requests.single.path, endsWith('/LiveTv/Programs'));
        final params = requests.single.queryParameters;
        final boundedNow = DateTime.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch ~/ 1000 * 1000, isUtc: true);
        expect(DateTime.parse(params['minEndDate']!), boundedNow);
        expect(DateTime.parse(params['maxStartDate']!), boundedNow.add(const Duration(seconds: 1)));
        expect(params['fields'], contains('Overview'));
        expect(find.text(t.liveTv.noPrograms), findsNothing);
        expect(find.text('Current show'), findsOneWidget);
        expect(find.text('Ended show'), findsNothing);
        expect(find.text('Future show'), findsNothing);
        expect(find.text('Unknown timing'), findsNothing);
        final hub = tester.widget<HubSection>(find.byType(HubSection));
        expect(hub.hub.items.single.backend, client.backend);
        expect(hub.hub.items.single.serverId, client.serverId);
        // Exercise the existing long-press details action with the parsed program.
        await tester.longPress(find.text('Current show'));
        await tester.pumpAndSettle();
        expect(find.text('A useful episode description.'), findsOneWidget);
        expect(find.text('S1E9 Heat Day'), findsOneWidget);
        expect(find.textContaining('TV-PG'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('${dialect.name} has a genuine empty state and refreshes on returning to the tab', (tester) async {
      var now = DateTime(2026, 9, 13, 20);
      var calls = 0;
      final client = testJellyfinClient(
        connection: testJellyfinConnection(dialect: dialect),
        handler: (_) async {
          calls++;
          return jsonResponse({
            'Items': calls == 1 ? [] : [_program('New current show', now, now.add(const Duration(minutes: 30)))],
          });
        },
      );
      await withClock(Clock(() => now), () async {
        await _pump(tester, [client]);
        expect(find.text(t.liveTv.noPrograms), findsOneWidget);
        final state = tester.state<WhatsOnTabState>(find.byType(WhatsOnTab));
        state.pauseRefresh();
        now = now.add(const Duration(hours: 2));
        state.resumeRefresh();
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(find.text('New current show'), findsOneWidget);
        expect(find.text(t.liveTv.noPrograms), findsNothing);
      });
    });
  }

  testWidgets('Plex discovery rows coexist with Jellyfin current programs', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final now = DateTime.now();
    final paths = <String>[];
    final plex = testPlexClient(
      epgProviders: [(identifier: 'provider-a', gridEndpoint: '/provider-a/grid', id: '2')],
      handler: (request) async {
        paths.add(request.url.path);
        return jsonResponse({
          'MediaContainer': {
            'Hub': [
              {
                'title': 'Plex recommendations',
                'key': 'plex-hub',
                'Metadata': [
                  {
                    'ratingKey': 'plex-program',
                    'key': '/library/metadata/plex-program',
                    'type': 'movie',
                    'title': 'Plex movie',
                  },
                ],
              },
            ],
          },
        });
      },
    );
    final jellyfin = testJellyfinClient(
      handler: (_) async => jsonResponse({
        'Items': [
          _program('Jellyfin show', now.subtract(const Duration(minutes: 10)), now.add(const Duration(hours: 1))),
        ],
      }),
    );
    await _pump(tester, [plex, jellyfin]);
    expect(paths, ['/provider-a/hubs/discover']);
    expect(find.text('Plex recommendations'), findsOneWidget);
    expect(find.text('Plex movie'), findsOneWidget);
    expect(find.text('Jellyfin show'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unavailable schedule does not hide programs from another server', (tester) async {
    final now = DateTime.now();
    final failed = testJellyfinClient(handler: (_) async => jsonResponse({}, status: 403));
    final healthy = testJellyfinClient(
      connection: testEmbyConnection(machineId: 'healthy'),
      handler: (_) async => jsonResponse({
        'Items': [
          _program('Healthy show', now.subtract(const Duration(minutes: 10)), now.add(const Duration(hours: 1))),
        ],
      }),
    );
    await _pump(tester, [failed, healthy]);
    expect(find.text('Healthy show'), findsOneWidget);
    expect(find.text(t.liveTv.noPrograms), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late refresh cannot replace a newer current-program snapshot', (tester) async {
    final now = DateTime.now();
    final pending = Completer<void>();
    var calls = 0;
    final client = testJellyfinClient(
      handler: (_) async {
        final call = ++calls;
        if (call == 2) await pending.future;
        return jsonResponse({
          'Items': [
            _program('Snapshot $call', now.subtract(const Duration(minutes: 10)), now.add(const Duration(hours: 1))),
          ],
        });
      },
    );
    await _pump(tester, [client]);
    final state = tester.state<WhatsOnTabState>(find.byType(WhatsOnTab));
    state.onRefreshTick();
    await tester.pump();
    state.onRefreshTick();
    await tester.pumpAndSettle();
    expect(find.text('Snapshot 3'), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Snapshot 3'), findsOneWidget);
    expect(find.text('Snapshot 2'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same program IDs on Jellyfin and Emby retain distinct server ownership', (tester) async {
    final now = DateTime.now();
    final clients = [
      for (final dialect in MediaBrowserDialect.values)
        testJellyfinClient(
          connection: testJellyfinConnection(machineId: dialect.name, dialect: dialect),
          handler: (_) async => jsonResponse({
            'Items': [
              _program('Current show', now.subtract(const Duration(minutes: 10)), now.add(const Duration(hours: 1))),
            ],
          }),
        ),
    ];
    await withClock(Clock.fixed(now), () async {
      await _pump(tester, clients);
      final hubs = tester.widgetList<HubSection>(find.byType(HubSection)).toList();
      expect(hubs, hasLength(2));
      expect(
        hubs.map((hub) => hub.hub.items.single.serverId).toSet(),
        clients.map((client) => client.serverId).toSet(),
      );
      expect(hubs.map((hub) => hub.hub.items.single.id).toSet(), {'Current show'});
      expect(tester.takeException(), isNull);
    });
  });
}

Map<String, Object?> _program(String title, DateTime start, DateTime end) => {
  'Id': title,
  'Name': title,
  'EpisodeTitle': 'Heat Day',
  'ParentIndexNumber': 1,
  'IndexNumber': 9,
  'Overview': 'A useful episode description.',
  'OfficialRating': 'TV-PG',
  'ChannelId': 'channel',
  'StartDate': start.toUtc().toIso8601String(),
  'EndDate': end.toUtc().toIso8601String(),
};

Future<void> _pump(WidgetTester tester, List<MediaServerClient> clients) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final fixture = testMultiServer(clients: clients);
  fixture.provider.debugSetLiveTvServersForTesting([
    for (final client in clients) LiveTvServerInfo(serverId: client.serverId, dvrKey: '', lineup: ''),
  ]);
  await tester.pumpWidget(
    TranslationProvider(
      child: InputModeTracker(
        child: ChangeNotifierProvider<MultiServerProvider>.value(
          value: fixture.provider,
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: Scaffold(
              body: WhatsOnTab(
                channels: [
                  for (final client in clients)
                    LiveTvChannel(key: 'channel', identifier: 'channel', title: 'News', serverId: client.serverId),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
