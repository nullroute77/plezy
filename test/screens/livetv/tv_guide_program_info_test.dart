import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/screens/livetv/tv_guide_program_info.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/optimized_media_image.dart';

void main() {
  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  for (final is24Hour in [false, true]) {
    testWidgets('TV info uses theme type and full width and shortens the description first (24h=$is24Hour)', (
      tester,
    ) async {
      final now = DateTime(2026, 11, 24, 23, 21);
      final start = DateTime(2026, 11, 24, 23);
      final end = DateTime(2026, 11, 25);
      final title = 'A very long program title with enough text to test the available width ' * 5;
      final description = ('The chefs turn up the heat in a summer cooking challenge. ' * 16).trim();
      final program = LiveTvProgram(
        title: 'Heat Day',
        grandparentTitle: title,
        parentIndex: 1,
        index: 9,
        summary: description,
        contentRating: 'TV-PG',
        thumb: '/episode/image',
        beginsAt: start.millisecondsSinceEpoch ~/ 1000,
        endsAt: end.millisecondsSinceEpoch ~/ 1000,
        live: true,
        premiere: true,
      );
      final channel = LiveTvChannel(key: 'food', title: 'Food Network');
      Future<void> pump(double height) => tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(is24Hour ? MonoPalette.dark : MonoPalette.light),
          home: MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: is24Hour, textScaler: const TextScaler.linear(1.5)),
            child: Scaffold(
              body: SizedBox(
                width: 750,
                height: height,
                child: TvGuideProgramInfo(channel: channel, program: program, now: now),
              ),
            ),
          ),
        ),
      );

      await pump(360);
      final titleFinder = find.text(title.trim());
      final subtitle = find.text('S1E9 Heat Day');
      final metadata = find.textContaining('Food Network');
      expect(tester.widget<Text>(find.text(description)).maxLines, 3);
      expect(tester.getTopLeft(titleFinder).dx, 16);
      expect(tester.getTopRight(titleFinder).dx, closeTo(726, 1));
      expect(find.byType(OptimizedMediaImage), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(find.text(t.liveTv.live), findsNothing);
      expect(find.text(t.liveTv.premiereBadge), findsNothing);
      expect(tester.takeException(), isNull);

      await pump(220);
      final time = is24Hour ? RegExp(r'23:00 – 00:00') : RegExp(r'11:00\sPM – 12:00\sAM');
      expect(find.textContaining(time), findsOneWidget);
      expect(find.textContaining('TV-PG · 39 min left'), findsOneWidget);
      final shortened = find.text(description);
      if (shortened.evaluate().isNotEmpty) expect(tester.widget<Text>(shortened).maxLines, lessThan(3));
      for (final line in [titleFinder, subtitle, metadata]) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: line, matching: find.byType(RichText)),
        );
        expect(paragraph.getTransformTo(null).getMaxScaleOnAxis(), closeTo(1, 0.001));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
