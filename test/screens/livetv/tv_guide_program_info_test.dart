import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/screens/livetv/tv_guide_program_info.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/status_pill.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';

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
              theme: monoTheme(dark ? MonoPalette.dark : MonoPalette.light),
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
        _expectUnscaledText(tester, find.text('Flavortown Food Fight'));
        _expectUnscaledText(tester, find.text('S1E9 Heat Day'));
        _expectUnscaledText(tester, find.textContaining('Food Network •'));
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

  for (final layout in [
    (width: 1280.0, height: 240.0, scale: 1.0),
    (width: 900.0, height: 190.0, scale: 1.5),
    (width: 430.0, height: 240.0, scale: 1.5),
    (width: 1920.0, height: 300.0, scale: 1.0),
  ]) {
    testWidgets('poster and long details use available width without shrinking ($layout)', (tester) async {
      tester.view.physicalSize = Size(layout.width, layout.height);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final servers = testMultiServer(clients: [_PosterClient()]);
      final title = 'A very long program title that uses all available horizontal space ' * 4;
      final summary = 'A detailed program description that should yield to readable headings. ' * 20;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: servers.provider,
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(layout.scale)),
              child: Scaffold(
                body: TvGuideProgramInfo(
                  channel: LiveTvChannel(key: 'food', title: 'A long channel name', contentRating: 'TV-PG'),
                  program: LiveTvProgram(
                    title: title,
                    programTitle: title,
                    episodeTitle: 'Heat Day',
                    parentIndex: 1,
                    index: 9,
                    summary: summary,
                    serverId: 'poster-server',
                    poster: '/poster',
                    beginsAt: DateTime(2026, 10, 18, 20).millisecondsSinceEpoch ~/ 1000,
                    endsAt: DateTime(2026, 10, 18, 21).millisecondsSinceEpoch ~/ 1000,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final titleFinder = find.text(title);
      _expectUnscaledText(tester, titleFinder);
      _expectUnscaledText(tester, find.text('S1E9 Heat Day'));
      _expectUnscaledText(tester, find.textContaining('A long channel name •'));
      final posterRect = tester.getRect(find.byType(OptimizedMediaImage));
      final titleRect = tester.getRect(titleFinder);
      expect(titleRect.left, closeTo(posterRect.right + 24, 0.1));
      expect(titleRect.right, closeTo(layout.width - 24, 0.1));
      expect(posterRect.width / posterRect.height, closeTo(2 / 3, 0.001));
      if (layout.height == 190) {
        // A short panel sacrifices the description, never the heading sizes.
        expect(find.text(summary), findsNothing);
      } else if (layout.width >= 1280) {
        expect(tester.widget<Text>(find.text(summary)).maxLines, 3);
      }
      expect(tester.takeException(), isNull);
    });
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

// Check the rendered transform: Text.style alone also passed when a FittedBox
// silently scaled the title and all the metadata down to half size.
void _expectUnscaledText(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.descendant(of: text, matching: find.byType(RichText)));
  expect(paragraph.getTransformTo(null).getMaxScaleOnAxis(), closeTo(1, 0.001));
}

final class _PosterClient implements MediaServerClient {
  @override
  ServerId get serverId => ServerId('poster-server');

  @override
  String get serverName => 'Poster server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities();

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) => '';

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
