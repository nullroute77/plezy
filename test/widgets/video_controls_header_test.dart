import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/utils/formatters.dart';
import 'package:plezy/services/jellyfin_mappers.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/widgets/video_controls_header.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  testWidgets('live header keeps channel and program together with duration underneath at both widths', (tester) async {
    for (final style in VideoHeaderStyle.values) {
      for (final width in [900.0, 240.0]) {
        await _pumpHeader(
          tester,
          metadata: _mappedItem({'Id': 'channel', 'Name': 'Channel 4', 'Type': 'TvChannel'}),
          style: style,
          width: width,
          liveProgram: LiveTvProgram(title: 'Evening News', beginsAt: 1000, endsAt: 2800),
        );
        final title = find.text('Channel 4 · Evening News');
        final duration = find.text(formatDurationTextual(1800000));
        expect(title, findsOneWidget);
        expect(duration, findsOneWidget);
        expect(tester.getTopLeft(duration).dy, greaterThan(tester.getTopLeft(title).dy));
        expect(tester.widget<Text>(title).overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
      }
    }
    await _pumpHeader(
      tester,
      metadata: _mappedItem({'Id': 'channel', 'Name': 'Channel 4', 'Type': 'TvChannel'}),
      style: VideoHeaderStyle.multiLine,
      liveProgram: LiveTvProgram(title: 'Next Program', beginsAt: 2800, endsAt: 6400),
    );
    expect(find.textContaining('Evening News'), findsNothing);
    expect(find.text('Channel 4 · Next Program'), findsOneWidget);
    expect(find.text(formatDurationTextual(3600000)), findsOneWidget);
  });

  testWidgets('title-less mapped movie builds with localized fallback in both layouts', (tester) async {
    final item = _mappedItem({'Id': 'movie-without-name', 'Type': 'Movie'});

    for (final style in VideoHeaderStyle.values) {
      await _pumpHeader(tester, metadata: item, style: style);

      expect(find.text(t.common.unknown), findsOneWidget, reason: style.name);
      expect(tester.takeException(), isNull, reason: style.name);
    }
  });

  testWidgets('title-less mapped episode keeps series identity and uses fallback in both layouts', (tester) async {
    final item = _mappedItem({
      'Id': 'episode-without-name',
      'Type': 'Episode',
      'SeriesName': 'Mapped Series',
      'ParentIndexNumber': 2,
      'IndexNumber': 3,
    });

    for (final style in VideoHeaderStyle.values) {
      await _pumpHeader(tester, metadata: item, style: style);

      final expectedEpisodeLine = switch (style) {
        VideoHeaderStyle.singleLine => 'Mapped Series · S2E3 · ${t.common.unknown}',
        VideoHeaderStyle.multiLine => 'S2 · E3 · ${t.common.unknown}',
      };
      expect(find.text(expectedEpisodeLine), findsOneWidget, reason: style.name);
      expect(tester.takeException(), isNull, reason: style.name);
    }
  });

  testWidgets('ordinary mapped episode wording remains unchanged in both layouts', (tester) async {
    final item = _mappedItem({
      'Id': 'titled-episode',
      'Type': 'Episode',
      'Name': 'The Arrival',
      'SeriesName': 'Mapped Series',
      'ParentIndexNumber': 1,
      'IndexNumber': 4,
    });

    for (final style in VideoHeaderStyle.values) {
      await _pumpHeader(tester, metadata: item, style: style);

      final expectedEpisodeLine = switch (style) {
        VideoHeaderStyle.singleLine => 'Mapped Series · S1E4 · The Arrival',
        VideoHeaderStyle.multiLine => 'S1 · E4 · The Arrival',
      };
      expect(find.text(expectedEpisodeLine), findsOneWidget, reason: style.name);
      expect(find.text(t.common.unknown), findsNothing, reason: style.name);
    }
  });
}

MediaItem _mappedItem(Map<String, dynamic> json) {
  return JellyfinMappers.mediaItem(
    json,
    serverId: ServerId('header-test-server'),
    serverName: 'Test Server',
    absolutizer: null,
  )!;
}

Future<void> _pumpHeader(
  WidgetTester tester, {
  required MediaItem metadata,
  required VideoHeaderStyle style,
  LiveTvProgram? liveProgram,
  double width = 900,
}) async {
  final watchTogether = WatchTogetherProvider();
  addTearDown(watchTogether.dispose);

  await tester.pumpWidget(
    TranslationProvider(
      child: ChangeNotifierProvider<WatchTogetherProvider>.value(
        value: watchTogether,
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SizedBox(
              width: width,
              child: VideoControlsHeader(
                metadata: metadata,
                style: style,
                liveProgram: liveProgram,
                showClock: false,
                onBack: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
