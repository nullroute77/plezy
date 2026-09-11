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
              'Name': 'Evening News',
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
      expect(find.text('Evening News'), findsOneWidget);
      expect(
        tester.widget<CollapsibleText>(find.byType(CollapsibleText)).text,
        'The latest headlines and local weather.',
      );
      expect(_metadata(tester), endsWith('${formatDurationTextual(30 * 60_000)} · TV-PG'));
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
      final runtime = formatDurationTextual(30 * 60_000);
      expect(_metadata(tester), endsWith(ratings.expected.isEmpty ? runtime : '$runtime · ${ratings.expected}'));
      expect(find.byType(CollapsibleText), findsNothing);
      expect(tester.takeException(), isNull);
    });
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
        title: 'Evening News',
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
    expect(_metadata(tester), endsWith('${formatDurationTextual(30 * 60_000)} · TV-PG'));
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

String _metadata(WidgetTester tester) =>
    tester.widget<Text>(find.textContaining(formatDurationTextual(30 * 60_000))).data!;

Future<void> _open(
  WidgetTester tester,
  LiveTvProgram program, {
  LiveTvChannel? channel,
  Size size = const Size(800, 600),
  double textScale = 1,
  VoidCallback? onTune,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    InputModeTracker(
      child: MaterialApp(
        theme: monoTheme(dark: true),
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
