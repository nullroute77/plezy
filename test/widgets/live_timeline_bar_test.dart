import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/utils/formatters.dart';
import 'package:plezy/widgets/video_controls/widgets/live_timeline_bar.dart';

import '../test_helpers/watch_together_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  group('LiveTimelineBar program boundaries', () {
    testWidgets('draws both bounds at their buffer fractions in either layout', (tester) async {
      for (final horizontalLayout in [true, false]) {
        await _pumpTimeline(
          tester,
          seeks: [],
          currentOffset: 60,
          horizontalLayout: horizontalLayout,
          programForStart: (start) => LiveProgramInfo(beginsAt: start + 30, durationMs: 60000),
        );
        _expectBoundaries(tester, [0.25, 0.75]);
      }
    });

    testWidgets('omits each off-screen bound without clamping to the buffer edge', (tester) async {
      for (final scenario in <({int start, int durationMs, List<double> fractions})>[
        (start: 40, durationMs: 10800000, fractions: [1 / 3]),
        (start: -30, durationMs: 120000, fractions: [0.75]),
        (start: -180, durationMs: 60000, fractions: []),
        (start: 180, durationMs: 60000, fractions: []),
        (start: -30, durationMs: 180000, fractions: []),
        (start: 0, durationMs: 120000, fractions: [0, 1]),
        (start: 119, durationMs: 1500, fractions: [119 / 120]),
      ]) {
        await _pumpTimeline(
          tester,
          seeks: [],
          currentOffset: 60,
          programForStart: (start) =>
              LiveProgramInfo(beginsAt: start + scenario.start, durationMs: scenario.durationMs),
        );
        _expectBoundaries(tester, scenario.fractions);
      }
    });

    testWidgets('uses the seekable window when the capture buffer advances', (tester) async {
      for (final startOffset in [30, 60]) {
        await _pumpTimeline(
          tester,
          seeks: [],
          currentOffset: 75,
          rangeStartOffset: startOffset,
          programForStart: (start) => LiveProgramInfo(beginsAt: start + 30, durationMs: 60000),
        );
        _expectBoundaries(tester, startOffset == 30 ? [0, 2 / 3] : [0.5]);
      }
    });

    testWidgets('leaves the timeline unmarked for missing or invalid timing and empty buffers', (tester) async {
      for (final program in [
        LiveProgramInfo.none,
        const LiveProgramInfo(durationMs: 60000),
        const LiveProgramInfo(beginsAt: 0, durationMs: 60000),
        const LiveProgramInfo(beginsAt: -1, durationMs: 60000),
        const LiveProgramInfo(beginsAt: 1),
        const LiveProgramInfo(beginsAt: 1, durationMs: 0),
        const LiveProgramInfo(beginsAt: 1, durationMs: -1),
      ]) {
        await _pumpTimeline(tester, seeks: [], currentOffset: 60, programForStart: (_) => program);
        _expectBoundaries(tester, []);
      }
      for (final durationMs in <int?>[null, 0, -1]) {
        await _pumpTimeline(
          tester,
          seeks: [],
          currentOffset: 60,
          programForStart: (start) => LiveProgramInfo(beginsAt: start + 30, durationMs: durationMs),
        );
        _expectBoundaries(tester, []);
      }
      await _pumpTimeline(
        tester,
        seeks: [],
        currentOffset: 0,
        rangeEndOffset: 0,
        programForStart: (start) => LiveProgramInfo(beginsAt: start, durationMs: 60000),
      );
      _expectBoundaries(tester, []);
    });

    testWidgets('replaces and clears markers when the tuned channel metadata changes', (tester) async {
      await _pumpTimeline(
        tester,
        seeks: [],
        currentOffset: 60,
        programForStart: (start) => LiveProgramInfo(id: 'channel-a', beginsAt: start + 30, durationMs: 60000),
      );
      final originalState = tester.state(find.byType(LiveTimelineBar));
      var painter = tester.widget<CustomPaint>(_timelinePaint).painter!;
      _expectBoundaries(tester, [0.25, 0.75]);

      await _pumpTimeline(
        tester,
        seeks: [],
        currentOffset: 60,
        programForStart: (start) => LiveProgramInfo(id: 'channel-b', beginsAt: start + 60, durationMs: 120000),
      );
      expect(tester.state(find.byType(LiveTimelineBar)), same(originalState));
      var nextPainter = tester.widget<CustomPaint>(_timelinePaint).painter!;
      expect(nextPainter.shouldRepaint(painter), isTrue);
      _expectBoundaries(tester, [0.5]);
      painter = nextPainter;

      await _pumpTimeline(tester, seeks: [], currentOffset: 60);
      nextPainter = tester.widget<CustomPaint>(_timelinePaint).painter!;
      expect(nextPainter.shouldRepaint(painter), isTrue);
      _expectBoundaries(tester, []);
    });
  });

  group('LiveTimelineBar semantics', () {
    testWidgets('exposes one named adjustable node without a duplicate timestamp', (tester) async {
      final semantics = tester.ensureSemantics();
      for (final horizontalLayout in [true, false]) {
        final seeks = <int>[];
        final harness = await _pumpTimeline(
          tester,
          seeks: seeks,
          currentOffset: 60,
          horizontalLayout: horizontalLayout,
        );

        final timeline = find.bySemanticsLabel(t.videoControls.timelineSlider);
        expect(timeline, findsOneWidget, reason: 'horizontalLayout=$horizontalLayout');

        final node = tester.getSemantics(timeline);
        final data = node.getSemanticsData();
        expect(data.label, t.videoControls.timelineSlider);
        expect(data.flagsCollection.isSlider, isTrue);
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        expect(data.value, _clock(harness.startEpoch + 60));
        expect(data.increasedValue, _clock(harness.startEpoch + 70));
        expect(data.decreasedValue, _clock(harness.startEpoch + 50));
        expect(data.hasAction(SemanticsAction.increase), isTrue);
        expect(data.hasAction(SemanticsAction.decrease), isTrue);
        expect(data.hasAction(SemanticsAction.scrollLeft), isFalse);
        expect(data.hasAction(SemanticsAction.scrollRight), isFalse);

        expect(
          find.bySemanticsLabel(_clock(harness.startEpoch + 60)),
          findsNothing,
          reason: 'the visual timestamp must not be announced separately when horizontalLayout=$horizontalLayout',
        );
      }
      semantics.dispose();
    });

    testWidgets('increase and decrease each emit one bounded absolute seek', (tester) async {
      final semantics = tester.ensureSemantics();
      final seeks = <int>[];
      final harness = await _pumpTimeline(tester, seeks: seeks, currentOffset: 60);
      final node = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider));

      node.owner!.performAction(node.id, SemanticsAction.increase);
      expect(seeks, [harness.startEpoch + 70]);

      node.owner!.performAction(node.id, SemanticsAction.decrease);
      expect(seeks, [harness.startEpoch + 70, harness.startEpoch + 50]);
      semantics.dispose();
    });

    testWidgets('short live window clamps actions and omits boundary no-ops', (tester) async {
      final semantics = tester.ensureSemantics();
      final seeks = <int>[];
      final startHarness = await _pumpTimeline(
        tester,
        seeks: seeks,
        currentOffset: 0,
        rangeEndOffset: 6,
        isAtLiveEdge: false,
      );

      var node = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider));
      var data = node.getSemanticsData();
      expect(data.hasAction(SemanticsAction.decrease), isFalse);
      expect(data.decreasedValue, isEmpty);
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.increasedValue, t.liveTv.live);

      node.owner!.performAction(node.id, SemanticsAction.increase);
      expect(seeks, [startHarness.startEpoch + 6]);

      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpTimeline(tester, seeks: seeks, currentOffset: 6, rangeEndOffset: 6, isAtLiveEdge: true);
      node = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider));
      data = node.getSemanticsData();
      expect(data.value, t.liveTv.live);
      expect(data.hasAction(SemanticsAction.increase), isFalse);
      expect(data.increasedValue, isEmpty);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);
      semantics.dispose();
    });

    testWidgets('supplied live-edge policy announces LIVE before the exact range end', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpTimeline(tester, seeks: <int>[], currentOffset: 116, rangeEndOffset: 120, isAtLiveEdge: true);

      final data = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider)).getSemanticsData();
      expect(data.value, t.liveTv.live);
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.increasedValue, t.liveTv.live);
      semantics.dispose();
    });

    testWidgets('disabled, callback-less, and invalid timelines expose no adjustments', (tester) async {
      final semantics = tester.ensureSemantics();

      for (final scenario in <({bool enabled, bool provideCallback, int rangeEnd})>[
        (enabled: false, provideCallback: true, rangeEnd: 120),
        (enabled: true, provideCallback: false, rangeEnd: 120),
        (enabled: true, provideCallback: true, rangeEnd: 0),
      ]) {
        final seeks = <int>[];
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpTimeline(
          tester,
          seeks: seeks,
          currentOffset: 0,
          rangeEndOffset: scenario.rangeEnd,
          enabled: scenario.enabled,
          provideSeekCallback: scenario.provideCallback,
          isAtLiveEdge: false,
        );

        final data = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider)).getSemanticsData();
        expect(data.flagsCollection.isEnabled, Tristate.isFalse, reason: '$scenario');
        expect(data.hasAction(SemanticsAction.increase), isFalse, reason: '$scenario');
        expect(data.hasAction(SemanticsAction.decrease), isFalse, reason: '$scenario');
        expect(data.increasedValue, isEmpty, reason: '$scenario');
        expect(data.decreasedValue, isEmpty, reason: '$scenario');
        expect(seeks, isEmpty, reason: '$scenario');
      }
      semantics.dispose();
    });
  });

  testWidgets('uses the calibrated source clock instead of adding its non-zero origin', (tester) async {
    final semantics = tester.ensureSemantics();
    final harness = await _pumpTimeline(
      tester,
      seeks: <int>[],
      currentOffset: 52,
      rangeEndOffset: 200,
      epochForPosition: (startEpoch, position) {
        const requestedOffset = 93;
        const sourceBaseline = 47;
        return startEpoch + requestedOffset + position.inSeconds - sourceBaseline;
      },
    );

    final data = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider)).getSemanticsData();
    expect(data.value, _clock(harness.startEpoch + 98));
    expect(data.decreasedValue, _clock(harness.startEpoch + 88));
    semantics.dispose();
  });

  testWidgets('pointer seek and desktop key routing remain intact', (tester) async {
    final seeks = <int>[];
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    var keyEvents = 0;
    final harness = await _pumpTimeline(
      tester,
      seeks: seeks,
      currentOffset: 60,
      focusNode: focusNode,
      programForStart: (start) => LiveProgramInfo(beginsAt: start + 30, durationMs: 60000),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowRight) {
          keyEvents++;
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );

    final paint = find.descendant(of: find.byType(LiveTimelineBar), matching: find.byType(CustomPaint));
    final topLeft = tester.getTopLeft(paint);
    final size = tester.getSize(paint);
    final gesture = await tester.startGesture(Offset(topLeft.dx + size.width * 0.75, topLeft.dy + size.height / 2));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(seeks, [harness.startEpoch + 90]);

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(keyEvents, 1);
    expect(seeks, [harness.startEpoch + 90]);
  });
}

String _clock(int epochSeconds) {
  return formatClockTime(DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000), is24Hour: true);
}

Future<({int startEpoch, FakeSyncPlayer player})> _pumpTimeline(
  WidgetTester tester, {
  required List<int> seeks,
  required int currentOffset,
  int rangeEndOffset = 120,
  int rangeStartOffset = 0,
  LiveProgramInfo Function(int startEpoch)? programForStart,
  bool isAtLiveEdge = false,
  bool enabled = true,
  bool provideSeekCallback = true,
  bool horizontalLayout = true,
  FocusNode? focusNode,
  KeyEventResult Function(FocusNode, KeyEvent)? onKeyEvent,
  int Function(int startEpoch, Duration position)? epochForPosition,
}) async {
  final startEpoch = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch ~/ 1000;
  final player = FakeSyncPlayer(position: Duration(seconds: currentOffset));
  addTearDown(player.dispose);

  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: true),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: SizedBox(
                width: 400,
                child: LiveTimelineBar(
                  player: player,
                  program: programForStart?.call(startEpoch) ?? LiveProgramInfo.none,
                  captureBuffer: CaptureBuffer(
                    startedAt: startEpoch.toDouble(),
                    seekStartSeconds: rangeStartOffset.toDouble(),
                    seekEndSeconds: rangeEndOffset.toDouble(),
                  ),
                  epochForPosition: (position) =>
                      epochForPosition?.call(startEpoch, position) ?? startEpoch + position.inSeconds,
                  isAtLiveEdge: isAtLiveEdge,
                  onSeekEnd: provideSeekCallback ? seeks.add : null,
                  focusNode: focusNode,
                  onKeyEvent: onKeyEvent,
                  horizontalLayout: horizontalLayout,
                  enabled: enabled,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  return (startEpoch: startEpoch, player: player);
}

Finder get _timelinePaint => find.descendant(of: find.byType(LiveTimelineBar), matching: find.byType(CustomPaint));

void _expectBoundaries(WidgetTester tester, List<double> fractions) {
  final size = tester.getSize(_timelinePaint);
  final painter = tester.widget<CustomPaint>(_timelinePaint).painter!;
  void paint(Canvas canvas) => painter.paint(canvas, size);
  expect(paint, paintsExactlyCountTimes(#drawRect, fractions.length));
  if (fractions.isEmpty) return;
  final matcher = paints;
  for (final fraction in fractions) {
    matcher.rect(
      rect: Rect.fromCenter(center: Offset(size.width * fraction, size.height / 2), width: 2, height: 12),
      color: Colors.white70,
    );
  }
  expect(paint, matcher);
}
