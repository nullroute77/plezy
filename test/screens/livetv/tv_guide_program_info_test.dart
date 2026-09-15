import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/screens/livetv/tv_guide_program_info.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/status_pill.dart';

void main() {
  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  for (final dark in [false, true]) {
    for (final is24Hour in [false, true]) {
      testWidgets('TV information retains metadata in a compact panel (dark=$dark, 24h=$is24Hour)', (tester) async {
        final now = DateTime(2026, 9, 15, 20, 21);
        final start = DateTime(2026, 9, 15, 20);
        final end = DateTime(2026, 9, 15, 21);
        final program = LiveTvProgram(
          title: 'Heat Day',
          grandparentTitle: 'Flavortown Food Fight',
          parentIndex: 1,
          index: 9,
          summary: 'The chefs turn up the heat in a summer cooking challenge. ' * 12,
          beginsAt: start.millisecondsSinceEpoch ~/ 1000,
          endsAt: end.millisecondsSinceEpoch ~/ 1000,
          live: true,
          isNew: true,
        );
        await withClock(
          Clock.fixed(now),
          () => tester.pumpWidget(
            MaterialApp(
              theme: monoTheme(dark: dark),
              home: MediaQuery(
                data: MediaQueryData(alwaysUse24HourFormat: is24Hour, textScaler: TextScaler.linear(1.5)),
                child: Scaffold(
                  body: SizedBox(
                    width: 900,
                    height: 190,
                    child: TvGuideProgramInfo(
                      channel: LiveTvChannel(key: 'food', title: 'Food Network', contentRating: 'TV-PG'),
                      program: program,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('Flavortown Food Fight'), findsOneWidget);
        expect(find.text('S1E9 Heat Day'), findsOneWidget);
        expect(find.textContaining('Food Network •'), findsOneWidget);
        expect(find.textContaining('TV-PG • 39 min left'), findsOneWidget);
        expect(
          find.textContaining(is24Hour ? RegExp('20:00 – 21:00') : RegExp(r'8:00\sPM – 9:00\sPM')),
          findsOneWidget,
        );
        expect(find.text(t.liveTv.live), findsNothing);
        expect(find.text(t.liveTv.newProgram), findsNothing);
        expect(find.byType(StatusPill), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('TV information shares placeholder filtering and omits status badges', (tester) async {
    Future<void> pump(LiveTvProgram program) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(height: 230, child: TvGuideProgramInfo(channel: null, program: program)),
        ),
      ),
    );
    await pump(LiveTvProgram(title: 'Show', programTitle: 'Show', episodeTitle: 'Episode 2000'));
    expect(find.text('Episode 2000'), findsNothing);
    expect(find.byType(StatusPill), findsNothing);
    await pump(
      LiveTvProgram(title: 'Show', programTitle: 'Show', episodeTitle: 'Episode 2000: A New Beginning', isNew: true),
    );
    expect(find.text('Episode 2000: A New Beginning'), findsOneWidget);
    expect(find.text(t.liveTv.newProgram), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
