import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../media/live_tv_timeline.dart';
import '../../../mpv/mpv.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../utils/formatters.dart';
import '../../clickable_cursor.dart';
import '../helpers/eager_horizontal_drag_recognizer.dart';

/// A backend-neutral epoch timeline. Program bounds describe the whole track;
/// only the intersection with the backend's playable grid accepts scrubbing.
class LiveTimelineBar extends StatefulWidget {
  final Player player;
  final LiveTvTimeline Function(Duration position) timelineForPosition;
  final ValueChanged<double>? onSeekEnd;
  final ValueChanged<int>? onSeekBy;
  final bool horizontalLayout;
  final FocusNode? focusNode;
  final KeyEventResult Function(FocusNode, KeyEvent)? onKeyEvent;
  final ValueChanged<bool>? onFocusChange;
  final bool enabled;

  const LiveTimelineBar({
    super.key,
    required this.player,
    required this.timelineForPosition,
    this.onSeekEnd,
    this.onSeekBy,
    this.horizontalLayout = true,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChange,
    this.enabled = true,
  });

  @override
  State<LiveTimelineBar> createState() => _LiveTimelineBarState();
}

class _LiveTimelineBarState extends State<LiveTimelineBar> {
  double? _dragEpoch;
  double? _dragRangeStart;
  double? _dragRangeEnd;
  Object? _dragProgram;
  late Stream<int> _positionSecondsStream;

  @override
  void initState() {
    super.initState();
    _bindPositionStream();
  }

  @override
  void didUpdateWidget(LiveTimelineBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _dragEpoch = null;
      _bindPositionStream();
    }
    if (!widget.enabled) _dragEpoch = null;
  }

  void _bindPositionStream() {
    _positionSecondsStream = widget.player.streams.position.map((position) => position.inSeconds).distinct();
  }

  LiveTvTimeline get _timeline => widget.timelineForPosition(widget.player.state.position);

  String _clock(double epoch) => formatClockTime(
    DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round()),
    is24Hour: MediaQuery.alwaysUse24HourFormatOf(context),
  );

  String _positionValue(LiveTvTimeline timeline) {
    if (timeline.isAtLive) return t.liveTv.live;
    final confirmed = timeline.confirmedPlayheadEpoch;
    if (confirmed != null) return _clock(confirmed);
    final estimate = timeline.estimatedPlayheadEpoch;
    if (estimate != null) return '${t.liveTv.timelineEstimated}: ${_clock(estimate)}';
    return t.liveTv.timelineUnavailable;
  }

  double? _fraction(LiveTvTimeline timeline, double? epoch) {
    if (epoch == null || !timeline.hasRange || epoch < timeline.startEpoch! || epoch > timeline.endEpoch!) return null;
    return (epoch - timeline.startEpoch!) / (timeline.endEpoch! - timeline.startEpoch!);
  }

  bool _canScrub(LiveTvTimeline timeline) =>
      widget.enabled &&
      widget.onSeekEnd != null &&
      timeline.hasRange &&
      timeline.scrubTarget(timeline.startEpoch!) != null;

  double? _relativeTarget(LiveTvTimeline timeline, int delta) {
    if (!widget.enabled || widget.onSeekBy == null) return null;
    final current = timeline.pendingSeekEpoch ?? (timeline.playback.active ? timeline.playback.epoch : null);
    if (current == null) return null;
    final target = timeline.seekable?.target(current + delta);
    return target == current ? null : target;
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
    stream: _positionSecondsStream,
    initialData: widget.player.state.position.inSeconds,
    builder: (context, snapshot) {
      final timeline = widget.timelineForPosition(Duration(seconds: snapshot.requireData));
      final labels = <String>[
        if (timeline.program != null) timeline.program!.displayTitle,
        if (timeline.mode == LiveTvTimelineMode.liveProgramFallback) t.liveTv.timelineLiveProgram,
        if (timeline.mode == LiveTvTimelineMode.buffer) t.liveTv.timelineBuffer,
        if (timeline.mode == LiveTvTimelineMode.unavailable) t.liveTv.timelineUnavailable,
        if (timeline.programDataStale) t.liveTv.timelineStale,
        if (timeline.playbackOutOfWindow) t.liveTv.unknownProgram,
        if (timeline.seekStatus == LiveTvSeekStatus.failed) t.liveTv.liveStreamFailed,
      ];
      final pending = _dragEpoch ?? timeline.pendingSeekEpoch;
      return Padding(
        padding: widget.horizontalLayout ? EdgeInsets.zero : const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(labels.join(' · '), style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 4),
            _buildSlider(timeline, pending),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(timeline.startEpoch == null ? '—' : _clock(timeline.startEpoch!), style: _timeStyle),
                Flexible(
                  child: ExcludeSemantics(child: Text(_positionValue(timeline), style: _timeStyle)),
                ),
                Text(timeline.endEpoch == null ? '—' : _clock(timeline.endEpoch!), style: _timeStyle),
              ],
            ),
            if (timeline.program != null && timeline.hasRange)
              Text(
                '${timeline.confirmedPlayheadEpoch == null ? '—' : formatDurationTimestamp(Duration(seconds: (timeline.confirmedPlayheadEpoch! - timeline.startEpoch!).floor()))} / ${formatDurationTimestamp(Duration(seconds: (timeline.endEpoch! - timeline.startEpoch!).round()))}',
                style: _timeStyle,
              ),
            if (pending != null) Text('${t.liveTv.timelinePending}: ${_clock(pending)}', style: _timeStyle),
          ],
        ),
      );
    },
  );

  static const _timeStyle = TextStyle(
    color: Colors.white70,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  Widget _buildSlider(LiveTvTimeline timeline, double? pending) {
    final canScrub = _canScrub(timeline);
    final increase = _relativeTarget(timeline, 10);
    final decrease = _relativeTarget(timeline, -10);
    return FocusableWrapper(
      focusNode: widget.focusNode,
      onKeyEvent: widget.enabled ? widget.onKeyEvent : null,
      onFocusChange: widget.onFocusChange,
      borderRadius: 8,
      autoScroll: false,
      useBackgroundFocus: true,
      disableScale: true,
      child: Builder(
        builder: (context) => ClickableCursor(
          enabled: canScrub,
          child: Semantics(
            label: t.videoControls.timelineSlider,
            slider: true,
            value: _positionValue(timeline),
            increasedValue: increase == null ? null : _clock(increase),
            decreasedValue: decrease == null ? null : _clock(decrease),
            enabled: canScrub || increase != null || decrease != null,
            onIncrease: increase == null ? null : () => widget.onSeekBy?.call(10),
            onDecrease: decrease == null ? null : () => widget.onSeekBy?.call(-10),
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              gestures: canScrub
                  ? <Type, GestureRecognizerFactory>{
                      EagerHorizontalDragGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<EagerHorizontalDragGestureRecognizer>(
                            () =>
                                EagerHorizontalDragGestureRecognizer(debugOwner: this)
                                  ..dragStartBehavior = DragStartBehavior.down,
                            (instance) {
                              instance.onStart = (details) => _applyDrag(details.localPosition.dx, context);
                              instance.onUpdate = (details) => _applyDrag(details.localPosition.dx, context);
                              instance.onEnd = (_) => _endDrag();
                              instance.onCancel = _endDrag;
                            },
                          ),
                    }
                  : const <Type, GestureRecognizerFactory>{},
              child: ExcludeSemantics(
                child: SizedBox(
                  width: double.infinity,
                  height: 24,
                  child: CustomPaint(
                    painter: _LiveTimelinePainter(
                      seekStart: _fraction(timeline, timeline.visibleSeekStart),
                      seekEnd: _fraction(timeline, timeline.visibleSeekEnd),
                      confirmed: _fraction(timeline, timeline.confirmedPlayheadEpoch),
                      estimated: _fraction(timeline, timeline.estimatedPlayheadEpoch),
                      pending: pending != null && timeline.contains(pending) ? _fraction(timeline, pending) : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _applyDrag(double dx, BuildContext context) {
    final box = context.findRenderObject();
    final timeline = _timeline;
    if (box is! RenderBox || box.size.width <= 0 || !_canScrub(timeline)) return;
    final fraction = (dx / box.size.width).clamp(0.0, 1.0);
    if (_dragEpoch != null && !_sameDragRange(timeline)) {
      setState(() => _dragEpoch = null);
      return;
    }
    final target = timeline.scrubTarget(timeline.startEpoch! + fraction * (timeline.endEpoch! - timeline.startEpoch!));
    _dragRangeStart = timeline.startEpoch;
    _dragRangeEnd = timeline.endEpoch;
    _dragProgram = timeline.program;
    setState(() => _dragEpoch = target);
  }

  bool _sameDragRange(LiveTvTimeline timeline) =>
      timeline.startEpoch == _dragRangeStart &&
      timeline.endEpoch == _dragRangeEnd &&
      identical(timeline.program, _dragProgram);

  void _endDrag() {
    final epoch = _dragEpoch;
    if (epoch == null) return;
    final timeline = _timeline;
    final target = _canScrub(timeline) && _sameDragRange(timeline) ? timeline.scrubTarget(epoch) : null;
    setState(() => _dragEpoch = null);
    if (target != null) widget.onSeekEnd?.call(target);
  }
}

class _LiveTimelinePainter extends CustomPainter {
  final double? seekStart;
  final double? seekEnd;
  final double? confirmed;
  final double? estimated;
  final double? pending;

  _LiveTimelinePainter({this.seekStart, this.seekEnd, this.confirmed, this.estimated, this.pending});

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, y - 4, size.width, 8), const Radius.circular(4)),
      Paint()..color = Colors.white.withValues(alpha: 0.15),
    );
    if (seekStart != null && seekEnd != null) {
      canvas.drawRect(
        Rect.fromLTRB(seekStart! * size.width, y - 4, seekEnd! * size.width, y + 4),
        Paint()..color = Colors.red.withValues(alpha: 0.4),
      );
    }
    if (confirmed != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(confirmed! * size.width, y), width: 4, height: 20),
          const Radius.circular(2),
        ),
        Paint()..color = Colors.red,
      );
    }
    if (estimated != null) {
      canvas.drawCircle(
        Offset(estimated! * size.width, y),
        6,
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    if (pending != null) {
      final x = pending! * size.width;
      final path = Path()
        ..moveTo(x, y - 9)
        ..lineTo(x + 6, y)
        ..lineTo(x, y + 9)
        ..lineTo(x - 6, y)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LiveTimelinePainter oldDelegate) =>
      seekStart != oldDelegate.seekStart ||
      seekEnd != oldDelegate.seekEnd ||
      confirmed != oldDelegate.confirmed ||
      estimated != oldDelegate.estimated ||
      pending != oldDelegate.pending;
}
