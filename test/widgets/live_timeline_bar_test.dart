import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/live_tv_timeline.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/utils/formatters.dart';
import 'package:plezy/widgets/video_controls/widgets/live_timeline_bar.dart';
import 'package:plezy/widgets/video_controls/widgets/timeline_slider.dart';
import 'package:plezy/widgets/video_controls/painters/buffer_range_painter.dart';

import '../test_helpers/watch_together_fakes.dart';

const _start = 1767268800.0;

LiveTvTimeline _timeline({
  double? position = 60,
  double? pending,
  bool estimated = false,
  bool unknown = false,
  bool withBuffer = true,
  bool withProgram = true,
  double bufferStart = 30,
  double bufferEnd = 180,
  double metadataNow = 60,
}) => LiveTvTimeline.resolve(
  playback: LiveTvPlaybackPosition(
    epoch: position == null ? null : _start + position,
    active: !unknown,
    accuracy: unknown
        ? LiveTvTimeAccuracy.unknown
        : estimated
        ? LiveTvTimeAccuracy.estimated
        : LiveTvTimeAccuracy.confirmed,
  ),
  seekable: withBuffer ? LiveTvSeekWindow(startEpoch: _start + bufferStart, endEpoch: _start + bufferEnd) : null,
  programs: withProgram
      ? [LiveTvProgram(title: 'Morning news', beginsAt: _start.toInt(), endsAt: _start.toInt() + 120)]
      : [],
  pendingSeekEpoch: pending == null ? null : _start + pending,
  metadataNowEpoch: _start + metadataNow,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  testWidgets('program labels cover full schedule while scrubbing clamps to playable intersection', (tester) async {
    final seeks = <double>[];
    await _pump(tester, timeline: _timeline(), seeks: seeks);
    expect(find.text('Morning news'), findsOneWidget);
    expect(find.text(_clock(_start)), findsOneWidget);
    expect(find.text(_clock(_start + 120)), findsOneWidget);
    await _tapTrack(tester, 0);
    await _tapTrack(tester, 1);
    expect(seeks, [_start + 30, _start + 119]);
  });

  testWidgets('accessibility relative skips use full buffer across the program boundary', (tester) async {
    final semantics = tester.ensureSemantics();
    final relative = <int>[];
    final absolute = <double>[];
    await _pump(tester, timeline: _timeline(position: 115, pending: 145), seeks: absolute, relative: relative);
    final node = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider));
    expect(node.getSemanticsData().value, _clock(_start + 115));
    expect(node.getSemanticsData().increasedValue, _clock(_start + 155));
    node.owner!.performAction(node.id, SemanticsAction.increase);
    expect(relative, [10]);
    expect(absolute, isEmpty);
    expect(find.textContaining(t.liveTv.timelinePending), findsNothing);
    semantics.dispose();
  });

  testWidgets('out-of-window fallback hides playback without inventing an edge timestamp', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, timeline: _timeline(position: -30), seeks: []);
    expect(find.textContaining(t.liveTv.timelineLiveProgram), findsNothing);
    final node = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider));
    expect(node.getSemanticsData().value, t.liveTv.timelineUnavailable);
    expect(_timelineSlider(tester).showPosition, isFalse);
    semantics.dispose();
  });

  testWidgets('estimated and pending positions reuse the movie playhead without visible status text', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, timeline: _timeline(estimated: true), seeks: []);
    final initialThumb = _thumbSize(tester);
    expect(initialThumb, const Size(4, 20));
    expect(_slider(tester).value, 60000);
    expect(find.byType(Text), findsNWidgets(3));

    await _pump(tester, timeline: _timeline(estimated: true, pending: 90), seeks: []);
    expect(_thumbSize(tester), initialThumb);
    expect(_slider(tester).value, 90000);
    final node = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider));
    expect(node.getSemanticsData().value, '${t.liveTv.timelineEstimated}: ${_clock(_start + 60)}');
    expect(find.textContaining(t.liveTv.timelineEstimated), findsNothing);
    expect(find.textContaining(t.liveTv.timelinePending), findsNothing);
    expect(find.textContaining(t.liveTv.timelineLiveProgram), findsNothing);
    expect(find.byType(Text), findsNWidgets(3));
    semantics.dispose();
  });

  testWidgets('hover uses the existing movie tooltip with program clock time', (tester) async {
    await _pump(tester, timeline: _timeline(estimated: true), seeks: []);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(TimelineSlider)));
    await tester.pump();
    expect(find.text(_clock(_start + 60)), findsOneWidget);
    expect(find.textContaining(t.liveTv.timelineEstimated), findsNothing);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(find.text(_clock(_start + 60)), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('scrubbing retains the same thumb and previews the clamped target', (tester) async {
    final seeks = <double>[];
    await _pump(tester, timeline: _timeline(estimated: true), seeks: seeks);
    final initialThumb = _thumbSize(tester);
    final rect = tester.getRect(find.byType(TimelineSlider));
    final gesture = await tester.startGesture(Offset(rect.left, rect.center.dy));
    await tester.pump();
    expect(_slider(tester).value, 30000);
    expect(_thumbSize(tester), initialThumb);
    await gesture.moveTo(Offset(rect.right - 1, rect.center.dy));
    await tester.pump();
    expect(_slider(tester).value, 119000);
    expect(_thumbSize(tester), initialThumb);
    await gesture.up();
    await tester.pump();
    expect(seeks, [_start + 119]);
  });

  testWidgets('retained interval uses the existing movie buffer painter', (tester) async {
    await _pump(tester, timeline: _timeline(), seeks: []);
    final painter = _painter(tester);
    expect(painter.duration, const Duration(seconds: 120));
    expect(painter.ranges.single.start, const Duration(seconds: 30));
    expect(painter.ranges.single.end, const Duration(seconds: 120));
    expect(_slider(tester).activeColor, Colors.transparent);
    expect(_slider(tester).thumbColor, Colors.white);
  });

  testWidgets('program changes while dragging cancel the old target', (tester) async {
    var current = _timeline();
    final seeks = <double>[];
    await _pump(tester, timeline: current, timelineBuilder: () => current, seeks: seeks);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(TimelineSlider)));
    await tester.pump();
    current = _timeline(withProgram: false);
    await gesture.up();
    await tester.pump();
    expect(seeks, isEmpty);
  });

  testWidgets('unknown and unavailable timelines never paint a playhead or seek', (tester) async {
    final semantics = tester.ensureSemantics();
    final seeks = <double>[];
    await _pump(tester, timeline: _timeline(unknown: true, withBuffer: false, withProgram: false), seeks: seeks);
    final data = tester.getSemantics(find.bySemanticsLabel(t.videoControls.timelineSlider)).getSemanticsData();
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.increase), isFalse);
    expect(_timelineSlider(tester).showPosition, isFalse);
    await _tapTrack(tester, 0.5);
    expect(seeks, isEmpty);
    semantics.dispose();
  });

  testWidgets('missing history explicitly uses buffer range', (tester) async {
    await _pump(tester, timeline: _timeline(withProgram: false), seeks: []);
    expect(find.text(t.liveTv.timelineBuffer), findsOneWidget);
    expect(find.text(_clock(_start + 30)), findsOneWidget);
    expect(find.text(_clock(_start + 180)), findsOneWidget);
  });

  testWidgets('program with no overlapping buffer disables pointer scrub', (tester) async {
    final seeks = <double>[];
    await _pump(tester, timeline: _timeline(bufferStart: 130), seeks: seeks);
    await _tapTrack(tester, 0.5);
    expect(seeks, isEmpty);
    expect(_painter(tester).ranges, isEmpty);
  });

  testWidgets('disabled controls and desktop focus routing remain intact', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var presses = 0;
    final seeks = <double>[];
    await _pump(
      tester,
      timeline: _timeline(),
      seeks: seeks,
      focus: focus,
      onKey: (_, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowRight) {
          presses++;
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(presses, 1);
    await _pump(tester, timeline: _timeline(), seeks: seeks, enabled: false);
    await _tapTrack(tester, 0.5);
    expect(seeks, isEmpty);
  });
}

TimelineSlider _timelineSlider(WidgetTester tester) => tester.widget<TimelineSlider>(find.byType(TimelineSlider));
Slider _slider(WidgetTester tester) => tester.widget<Slider>(find.byType(Slider));
Size? _thumbSize(WidgetTester tester) =>
    tester.widget<SliderTheme>(find.byType(SliderTheme)).data.thumbSize?.resolve({});
BufferRangePainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is BufferRangePainter),
            )
            .painter!
        as BufferRangePainter;

Future<void> _tapTrack(WidgetTester tester, double fraction) async {
  final rect = tester.getRect(find.byType(TimelineSlider));
  final gesture = await tester.startGesture(Offset(rect.left + (rect.width - 1) * fraction, rect.center.dy));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

String _clock(double epoch) =>
    formatClockTime(DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round()), is24Hour: true);

Future<void> _pump(
  WidgetTester tester, {
  required LiveTvTimeline timeline,
  required List<double> seeks,
  LiveTvTimeline Function()? timelineBuilder,
  List<int>? relative,
  bool enabled = true,
  FocusNode? focus,
  KeyEventResult Function(FocusNode, KeyEvent)? onKey,
}) async {
  final player = FakeSyncPlayer(position: const Duration(seconds: 60));
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
                  timelineForPosition: (_) => timelineBuilder?.call() ?? timeline,
                  onSeekEnd: seeks.add,
                  onSeekBy: relative?.add,
                  enabled: enabled,
                  focusNode: focus,
                  onKeyEvent: onKey,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
