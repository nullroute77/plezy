import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/live_tv_timeline.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/services/jellyfin_mappers.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/widgets/video_controls_header.dart';
import 'package:provider/provider.dart';

import '../test_helpers/watch_together_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  for (final (episode, expectedSubtitle) in [
    ('  The Arrival  ', 'The Arrival'),
    ('Episode 2000: A New Beginning', 'Episode 2000: A New Beginning'),
    ('', null),
    ('   ', null),
    ('  ePiSoDe   009  ', null),
  ]) {
    testWidgets('live header formats episode subtext "$episode" at normal and narrow widths', (tester) async {
      final program = LiveTvProgram(
        title: episode,
        grandparentTitle: '  Test Series  ',
        parentIndex: 1,
        index: 9,
        beginsAt: 1000,
        endsAt: 4600,
      );
      final expected = ['Test Series', ?expectedSubtitle, '1h'].join(' · ');
      for (final width in [900.0, 240.0]) {
        await _pumpHeader(
          tester,
          metadata: _mappedItem({'Id': 'channel', 'Type': 'TvChannel', 'Name': 'Test Channel'}),
          style: VideoHeaderStyle.singleLine,
          liveProgram: program,
          width: width,
        );
        expect(find.text('Test Channel'), findsOneWidget);
        final subtitle = tester.widget<Text>(find.text(expected));
        expect(subtitle.maxLines, 1);
        expect(subtitle.overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('live program without an episode title keeps one separator before duration', (tester) async {
    await _pumpHeader(
      tester,
      metadata: _mappedItem({'Id': 'channel', 'Type': 'TvChannel', 'Name': 'Test Channel'}),
      style: VideoHeaderStyle.multiLine,
      liveProgram: LiveTvProgram(title: '  Evening News  ', beginsAt: 1000, endsAt: 4600),
    );
    expect(find.text('Evening News · 1h'), findsOneWidget);
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
  final player = liveProgram == null ? null : FakeSyncPlayer();
  if (player != null) addTearDown(player.dispose);

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
                onBack: () {},
                showClock: false,
                player: player,
                liveTimelineForPosition: liveProgram == null
                    ? null
                    : (_) => LiveTvTimeline.resolve(
                        playback: const LiveTvPlaybackPosition(
                          epoch: 1100,
                          active: true,
                          accuracy: LiveTvTimeAccuracy.estimated,
                        ),
                        programs: [liveProgram],
                        metadataNowEpoch: 1100,
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
