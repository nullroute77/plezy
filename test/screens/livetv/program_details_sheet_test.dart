import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/screens/livetv/program_details_sheet.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/formatters.dart';
import 'package:plezy/widgets/collapsible_text.dart';
import 'package:plezy/widgets/status_pill.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/http_fixtures.dart';

void main() {
  setUpAll(() async => initializeDateFormatting('en'));
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  for (final dialect in MediaBrowserDialect.values) {
    testWidgets('${dialect.name} schedule overview reaches the popup with a formatted age rating', (tester) async {
      final client = testJellyfinClient(
        connection: testJellyfinConnection(dialect: dialect),
        handler: (request) async => jsonResponse({
          'Items': [
            {
              'Id': 'program',
              'Name': 'Flavortown Food Fight',
              'EpisodeTitle': 'Heat Day',
              'IsSeries': true,
              'ParentIndexNumber': 1,
              'IndexNumber': 9,
              'StartDate': '2026-09-10T20:00:00Z',
              'EndDate': '2026-09-10T20:30:00Z',
              'OfficialRating': 'US/TV-PG',
              if (request.url.queryParameters['fields']?.split(',').contains('Overview') == true)
                'Overview': 'The latest headlines and local weather.',
            },
          ],
        }),
      );
      addTearDown(client.close);
      final program = (await client.liveTv.fetchSchedule()).single;
      await _open(tester, program);
      expect(find.text('Flavortown Food Fight'), findsOneWidget);
      expect(find.text('S1E9 Heat Day'), findsOneWidget);
      expect(find.text(t.liveTv.newProgram), dialect == MediaBrowserDialect.jellyfin ? findsOneWidget : findsNothing);
      expect(
        tester.widget<CollapsibleText>(find.byType(CollapsibleText)).text,
        'The latest headlines and local weather.',
      );
      expect(_metadata(tester), endsWith(' · TV-PG'));
      expect(_metadata(tester), isNot(contains(formatDurationTextual(30 * 60_000))));
      expect(tester.takeException(), isNull);
    });
  }

  for (final ratings in [
    (name: 'program takes precedence', program: 'us/TV-PG', channel: 'TV-14', expected: 'TV-PG'),
    (name: 'channel fallback', program: null, channel: 'gb/15', expected: '15'),
    (name: 'blank program fallback', program: '  ', channel: '  TV-MA  ', expected: 'TV-MA'),
    (name: 'missing ratings', program: null, channel: null, expected: ''),
    (name: 'blank ratings', program: ' ', channel: ' ', expected: ''),
  ]) {
    testWidgets('popup metadata: ${ratings.name}', (tester) async {
      await _open(
        tester,
        LiveTvProgram(title: 'Program', beginsAt: 1800000000, endsAt: 1800001800, contentRating: ratings.program),
        channel: LiveTvChannel(key: 'channel', title: 'Channel', contentRating: ratings.channel),
      );
      final window = _window(
        DateTime.fromMillisecondsSinceEpoch(1800000000000),
        DateTime.fromMillisecondsSinceEpoch(1800001800000),
      );
      expect(_metadata(tester), 'Channel · $window${ratings.expected.isEmpty ? '' : ' · ${ratings.expected}'}');
      expect(find.byType(CollapsibleText), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Plex separates the primary title, episode label, and metadata in order', (tester) async {
    final program = LiveTvProgram.fromJson({
      'title': 'Heat Day',
      'grandparentTitle': 'Flavortown Food Fight',
      'parentIndex': 1,
      'index': 9,
      'beginsAt': 1800000000,
      'endsAt': 1800001800,
      'contentRating': 'TV-PG',
      'new': true,
    });
    await _open(
      tester,
      program,
      channel: LiveTvChannel(key: 'channel', title: 'Food Network'),
    );
    final title = find.text('Flavortown Food Fight');
    final subtitle = find.text('S1E9 Heat Day');
    expect(title, findsOneWidget);
    expect(subtitle, findsOneWidget);
    expect(tester.getTopLeft(subtitle).dy, greaterThan(tester.getBottomLeft(title).dy));
    expect(tester.getTopLeft(find.text(_metadata(tester))).dy, greaterThan(tester.getBottomLeft(subtitle).dy));
    expect(_metadata(tester), 'Food Network · ${_window(program.startTime!, program.endTime!)} · TV-PG');
  });

  for (final entry in [
    (name: 'episode only', season: null, episode: 9, title: 'Heat Day', expected: 'E9 Heat Day'),
    (name: 'season only', season: 1, episode: null, title: 'Heat Day', expected: 'S1 Heat Day'),
    (name: 'specials season', season: 0, episode: 9, title: 'Heat Day', expected: 'S0E9 Heat Day'),
    (name: 'title without numbers', season: null, episode: null, title: 'The 100', expected: 'The 100'),
    (
      name: 'numbered legitimate title',
      season: 1,
      episode: 9,
      title: 'Episode 2000: A New Beginning',
      expected: 'S1E9 Episode 2000: A New Beginning',
    ),
    (name: 'placeholder with numbers', season: 1, episode: 9, title: ' Episode 2000 ', expected: 'S1E9'),
    (name: 'placeholder alone', season: null, episode: null, title: 'Episode 2000', expected: null),
    (name: 'absent subtext', season: null, episode: null, title: null, expected: null),
    (name: 'blank subtext', season: null, episode: null, title: '  ', expected: null),
  ]) {
    testWidgets('popup subtext: ${entry.name}', (tester) async {
      await _open(
        tester,
        LiveTvProgram(title: 'Program', episodeTitle: entry.title, parentIndex: entry.season, index: entry.episode),
      );
      if (entry.expected != null) {
        expect(find.text(entry.expected!), findsOneWidget);
      } else {
        final column = tester.widget<Column>(
          find.ancestor(of: find.text('Program'), matching: find.byType(Column)).first,
        );
        // No subtitle widget or its spacing when no useful content remains.
        expect(column.children, hasLength(3));
      }
      expect(find.text('Episode 2000'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final appearance in [
    (name: 'light', dark: false, oled: false),
    (name: 'dark', dark: true, oled: false),
    (name: 'OLED', dark: true, oled: true),
  ]) {
    for (final flags in [
      (name: 'live beats new', live: true, isNew: true, premiere: null, repeat: null, label: 'LIVE'),
      (name: 'new', live: null, isNew: true, premiere: null, repeat: null, label: 'NEW'),
      (name: 'premiere', live: false, isNew: null, premiere: true, repeat: null, label: 'NEW'),
      (name: 'repeat veto', live: false, isNew: true, premiere: null, repeat: true, label: null),
      (name: 'missing metadata while airing', live: null, isNew: null, premiere: null, repeat: null, label: null),
    ]) {
      testWidgets('${appearance.name} popup badge: ${flags.name}', (tester) async {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await _open(
          tester,
          LiveTvProgram(
            title: 'Program',
            live: flags.live,
            isNew: flags.isNew,
            premiere: flags.premiere,
            repeat: flags.repeat,
            beginsAt: now - 300,
            endsAt: now + 1500,
          ),
          dark: appearance.dark,
          oled: appearance.oled,
        );
        if (flags.label == null) {
          expect(find.byType(StatusPill), findsNothing);
        } else {
          final badge = find.byType(StatusPill);
          expect(badge, findsOneWidget);
          expect(find.descendant(of: badge, matching: find.text(flags.label!)), findsOneWidget);
          expect(tester.getTopLeft(badge).dx - tester.getTopRight(find.text('Program')).dx, 4);
          expect(tester.getCenter(badge).dy, closeTo(tester.getCenter(find.text('Program')).dy, 0.01));
          if (flags.label == 'NEW') {
            final pill = tester.widget<StatusPill>(badge);
            final luminances = [pill.foregroundColor.computeLuminance(), pill.color.computeLuminance()]..sort();
            expect((luminances.last + 0.05) / (luminances.first + 0.05), greaterThanOrEqualTo(4.5));
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('rating remains available without runtime and whitespace overview is omitted', (tester) async {
    await _open(tester, LiveTvProgram(title: 'Program', contentRating: 'TV-G', summary: ' \n '));
    expect(find.text('TV-G'), findsOneWidget);
    expect(find.byType(CollapsibleText), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow scaled popup keeps rating readable and description expandable with remote focus', (tester) async {
    final summary = List.filled(8, 'The latest local headlines, sport, and weather from around the region.').join(' ');
    var tuned = false;
    await _open(
      tester,
      LiveTvProgram(
        title: 'Flavortown Food Fight with a longer title',
        episodeTitle: 'Heat Day',
        parentIndex: 1,
        index: 9,
        live: true,
        isNew: true,
        beginsAt: 1800000000,
        endsAt: 1800001800,
        summary: summary,
        contentRating: 'TV-PG',
      ),
      channel: LiveTvChannel(key: 'channel', title: 'Long channel name'),
      size: const Size(400, 700),
      textScale: 1.5,
      onTune: () => tuned = true,
    );
    expect(_metadata(tester), endsWith(' · TV-PG'));
    expect(_metadata(tester), isNot(contains(formatDurationTextual(30 * 60_000))));
    expect(find.text('S1E9 Heat Day'), findsOneWidget);
    expect(find.text(t.liveTv.live), findsOneWidget);
    expect(find.text(t.liveTv.newProgram), findsNothing);
    final description = tester.widget<CollapsibleText>(find.byType(CollapsibleText));
    description.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(
      find.descendant(of: find.byType(CollapsibleText), matching: find.byType(Text)).first,
    );
    expect(text.textSpan?.toPlainText() ?? text.data, summary);
    expect(tester.takeException(), isNull);
    final button = find.widgetWithText(FilledButton, t.liveTv.watchChannel);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(tuned, isTrue);
    expect(find.byType(CollapsibleText), findsNothing);
  });
}

String _metadata(WidgetTester tester) => tester.widget<Text>(find.textContaining(' - ')).data!;

String _window(DateTime start, DateTime end) =>
    '${formatClockTime(start, is24Hour: false)} - ${formatClockTime(end, is24Hour: false)}';

Future<void> _open(
  WidgetTester tester,
  LiveTvProgram program, {
  LiveTvChannel? channel,
  Size size = const Size(800, 600),
  double textScale = 1,
  bool dark = true,
  bool oled = false,
  VoidCallback? onTune,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    InputModeTracker(
      child: MaterialApp(
        theme: monoTheme(dark: dark, oled: oled),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showProgramDetailsSheet(
                context,
                program: program,
                channel: channel,
                posterUrl: null,
                onTuneChannel: onTune,
              ),
              child: const Text('Open program'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open program'));
  await tester.pumpAndSettle();
}
