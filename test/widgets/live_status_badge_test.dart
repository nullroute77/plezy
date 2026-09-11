import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/screens/livetv/program_details_sheet.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/status_pill.dart';
import 'package:plezy/widgets/video_controls/desktop_video_controls.dart';
import 'package:plezy/widgets/video_controls/mobile_video_controls.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/watch_together_fakes.dart';

const _screenshotDir = String.fromEnvironment('GUIDE_SCREENSHOT_DIR');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('en');
    if (_screenshotDir.isNotEmpty) {
      const previewFontPath = String.fromEnvironment('GUIDE_PREVIEW_FONT_PATH');
      final font = previewFontPath.isEmpty
          ? rootBundle.load('assets/go-noto-current-regular.ttf')
          : Future.value(ByteData.sublistView(File(previewFontPath).readAsBytesSync()));
      await (FontLoader('BadgePreview')..addFont(font)).load();
      await (FontLoader(
        'packages/material_symbols_icons/MaterialSymbolsRounded',
      )..addFont(rootBundle.load('packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf'))).load();
    }
  });
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  for (final desktop in [true, false]) {
    for (final scenario in [
      (name: 'on-demand', live: false, buffered: false, edge: true),
      (name: 'unbuffered', live: true, buffered: false, edge: true),
      (name: 'live-edge', live: true, buffered: true, edge: true),
      (name: 'behind-live', live: true, buffered: true, edge: false),
    ]) {
      testWidgets('${desktop ? 'desktop' : 'mobile'} player shares badge and preserves ${scenario.name} visibility', (
        tester,
      ) async {
        tester.view.physicalSize = desktop ? const Size(1200, 720) : const Size(430, 860);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        resetSharedPreferencesForTest();
        SettingsService.resetForTesting();
        final settings = await SettingsService.getInstance();
        final player = FakeSyncPlayer();
        addTearDown(player.dispose);
        final volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
        addTearDown(volume.dispose);
        final watchTogether = WatchTogetherProvider();
        addTearDown(watchTogether.dispose);
        final buffer = scenario.buffered
            ? const CaptureBuffer(startedAt: 1800000000, seekStartSeconds: 0, seekEndSeconds: 1800)
            : null;
        final metadata = testMediaItem(id: 'live-badge', title: 'Live sports');
        final controls = desktop
            ? DesktopVideoControls(
                useDpadNavigation: false,
                player: player,
                volumeController: volume,
                metadata: metadata,
                onPlayPause: () {},
                chapters: const [],
                chaptersLoaded: true,
                seekTimeSmall: 10,
                onSeekToPreviousChapter: () {},
                onSeekToNextChapter: () {},
                onSeek: (_) {},
                onSeekEnd: (_) {},
                getReplayIcon: (_) => Icons.replay,
                getForwardIcon: (_) => Icons.forward_10,
                trackControlsState: TrackControlsState(canControl: true, isLive: scenario.live),
                captureBuffer: buffer,
                isAtLiveEdge: scenario.edge,
                liveEpochForPosition: (position) => 1800000000 + position.inSeconds,
              )
            : MobileVideoControls(
                player: player,
                metadata: metadata,
                chapters: const [],
                chaptersLoaded: true,
                seekTimeSmall: 10,
                trackChapterControls: const SizedBox.shrink(),
                onSeek: (_) {},
                onSeekEnd: (_) {},
                onPlayPause: () {},
                isLive: scenario.live,
                captureBuffer: buffer,
                isAtLiveEdge: scenario.edge,
                liveEpochForPosition: (position) => 1800000000 + position.inSeconds,
              );
        await tester.pumpWidget(
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether, child: _shell(controls)),
        );
        await tester.pumpAndSettle();
        final visible = scenario.live && (desktop ? !scenario.buffered || scenario.edge : !scenario.buffered);
        if (visible) {
          _expectLiveBadge(tester);
          if (scenario.name == 'unbuffered') await _capture(tester, 'player-${desktop ? 'desktop' : 'mobile'}');
        } else {
          expect(find.byType(StatusPill), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final airing in [false, true]) {
    testWidgets('program popup shares badge and preserves airing=$airing visibility', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final program = LiveTvProgram(
        title: 'Evening News',
        summary: 'The latest headlines and local weather.',
        // Keep the sheet's existing currently-airing condition, independently
        // of the broadcast-designation condition used by the guide cards.
        live: !airing,
        beginsAt: airing ? now - 300 : now + 3600,
        endsAt: airing ? now + 1500 : now + 5400,
      );
      await tester.pumpWidget(
        _shell(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showProgramDetailsSheet(
                context,
                program: program,
                channel: null,
                posterUrl: null,
                onTuneChannel: null,
              ),
              child: const Text('Open program'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open program'));
      await tester.pumpAndSettle();
      if (airing) {
        _expectLiveBadge(tester);
        await _capture(tester, 'program-popup');
      } else {
        expect(find.byType(StatusPill), findsNothing);
      }
      expect(find.text('Evening News'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('shared LIVE badge keeps compact bounds and optical alignment with text scale $scale', (tester) async {
      await tester.pumpWidget(
        _shell(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [StatusPill.live()]),
            ),
          ),
        ),
      );
      _expectLiveBadge(tester);
      expect(tester.getSize(find.byType(StatusPill)).width, lessThan(100));
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _shell(Widget child) {
  final theme = monoTheme(dark: true);
  return InputModeTracker(
    child: MaterialApp(
      theme: _screenshotDir.isEmpty
          ? theme
          : theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'BadgePreview')),
      builder: (context, child) => RepaintBoundary(key: const ValueKey('badge-capture'), child: child!),
      home: Scaffold(body: child),
    ),
  );
}

void _expectLiveBadge(WidgetTester tester) {
  final badge = find.byType(StatusPill);
  expect(badge, findsOneWidget);
  final label = find.descendant(of: badge, matching: find.text(t.liveTv.live));
  expect(label, findsOneWidget);
  final text = tester.widget<Text>(label);
  expect(text.style?.color, Colors.white);
  expect(text.textAlign, TextAlign.center);
  expect(text.textHeightBehavior?.leadingDistribution, TextLeadingDistribution.even);
  final decoration =
      tester.widget<Container>(find.descendant(of: badge, matching: find.byType(Container))).decoration!
          as BoxDecoration;
  expect(decoration.color, Colors.red.shade700);
  expect(decoration.border, isNull);
  expect(decoration.borderRadius, BorderRadius.circular(3));
  final badgeRect = tester.getRect(badge);
  final labelRect = tester.getRect(label);
  expect(labelRect.center.dx, closeTo(badgeRect.center.dx, 0.01));
  expect(labelRect.center.dy, closeTo(badgeRect.center.dy - 1, 0.01));
  expect(labelRect.left - badgeRect.left, closeTo(4, 0.01));
  expect(labelRect.top - badgeRect.top, closeTo(0, 0.01));
  expect(badgeRect.bottom - labelRect.bottom, closeTo(2, 0.01));
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_screenshotDir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('badge-capture')));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(_screenshotDir).createSync(recursive: true);
      File('$_screenshotDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
