import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/livetv_capture_buffer.dart';
import '../../../models/livetv_program.dart';
import '../../../mpv/mpv.dart';
import '../../../focus/card_focus_scope.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../utils/formatters.dart';
import '../../clickable_cursor.dart';
import '../helpers/eager_horizontal_drag_recognizer.dart';
import '../helpers/render_geometry.dart';
import 'player_focus_disc.dart';

/// Timeline bar for live TV time-shift.
///
/// Listens to player position while delegating the player-clock-to-epoch
/// mapping to [epochForPosition], the same mapping used by seek commands and
/// timeline heartbeats. A current program supplies the displayed range;
/// pointer seeks remain limited to its intersection with the capture buffer.
class LiveTimelineBar extends StatefulWidget {
  final Player player;
  final CaptureBuffer captureBuffer;
  final LiveTvProgram? program;
  final int Function(Duration position) epochForPosition;
  final bool isAtLiveEdge;
  final ValueChanged<int>? onSeekEnd;
  final bool horizontalLayout;
  final FocusNode? focusNode;
  final KeyEventResult Function(FocusNode, KeyEvent)? onKeyEvent;
  final ValueChanged<bool>? onFocusChange;
  final bool enabled;

  const LiveTimelineBar({
    super.key,
    required this.player,
    required this.captureBuffer,
    this.program,
    required this.epochForPosition,
    this.isAtLiveEdge = true,
    this.onSeekEnd,
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
  bool _isDragging = false;
  int _dragPositionEpoch = 0;
  int? _hoverEpoch;

  /// Position emits ~4x/sec but everything rendered is whole seconds, so
  /// rebuild only when the second changes (see ContentStrip's chapter index
  /// stream for the same pattern).
  late Stream<int> _positionSecondsStream;

  @override
  void initState() {
    super.initState();
    _bindPositionStream();
  }

  @override
  void didUpdateWidget(LiveTimelineBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) _bindPositionStream();
    if (oldWidget.program?.beginsAt != widget.program?.beginsAt ||
        oldWidget.program?.endsAt != widget.program?.endsAt ||
        oldWidget.player != widget.player) {
      _isDragging = false;
      _hoverEpoch = null;
    }
  }

  void _bindPositionStream() {
    _positionSecondsStream = widget.player.streams.position.map((position) => position.inSeconds).distinct();
  }

  bool get _hasProgram => widget.program?.durationMs != null;
  int get _rangeStart => _hasProgram ? widget.program!.beginsAt! : widget.captureBuffer.seekableStartEpoch;
  int get _rangeEnd => _hasProgram ? widget.program!.endsAt! : widget.captureBuffer.seekableEndEpoch;
  int get _seekStart => math.max(_rangeStart, widget.captureBuffer.seekableStartEpoch);
  int get _seekEnd => math.min(_rangeEnd, widget.captureBuffer.seekableEndEpoch);

  int _currentEpoch(int positionSeconds) => widget.epochForPosition(Duration(seconds: positionSeconds));

  int _displayPosition(int positionSeconds) => _isDragging ? _dragPositionEpoch : _currentEpoch(positionSeconds);

  String _formatEpochTime(BuildContext context, int epochSeconds, {bool includeSeconds = false}) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    return formatClockTime(dt, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context), includeSeconds: includeSeconds);
  }

  bool get _hasSeekableRange => _seekEnd > _seekStart;

  int _normalizedEpoch(int epoch) {
    if (!_hasSeekableRange) return _rangeStart;
    return epoch.clamp(_seekStart, _seekEnd);
  }

  int _semanticTarget(int displayPos, int deltaSeconds) {
    final current = _normalizedEpoch(displayPos);
    return (current + deltaSeconds).clamp(_seekStart, _seekEnd);
  }

  String _semanticEpochValue(int epoch, {bool isCurrent = false}) {
    if ((isCurrent && widget.isAtLiveEdge) || (_hasSeekableRange && epoch >= widget.captureBuffer.seekableEndEpoch)) {
      return t.liveTv.live;
    }
    return _formatEpochTime(context, epoch);
  }

  void _semanticSeekBy(int displayPos, int deltaSeconds) {
    final seek = widget.onSeekEnd;
    if (!widget.enabled || seek == null || !_hasSeekableRange) return;

    final current = _normalizedEpoch(displayPos);
    final target = _semanticTarget(current, deltaSeconds);
    if (target != current) seek(target);
  }

  double _epochToFraction(int epoch) {
    final range = _rangeEnd - _rangeStart;
    if (range <= 0) return 1.0; // No range yet → show at live edge (right)
    return ((epoch - _rangeStart) / range).clamp(0.0, 1.0);
  }

  int _fractionToEpoch(double fraction) {
    final range = _rangeEnd - _rangeStart;
    return (_rangeStart + (fraction * range).round()).clamp(_rangeStart, _rangeEnd);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _positionSecondsStream,
      initialData: widget.player.state.position.inSeconds,
      builder: (context, snapshot) {
        final displayPos = _displayPosition(snapshot.requireData);

        if (widget.horizontalLayout) {
          return _buildHorizontalLayout(displayPos);
        }
        return _buildVerticalLayout(displayPos);
      },
    );
  }

  Widget _buildHorizontalLayout(int displayPos) {
    return Row(
      children: [
        ExcludeSemantics(
          child: Text(
            _formatEpochTime(context, _hasProgram ? _rangeStart : displayPos),
            style: const TextStyle(color: Colors.white70, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: _buildSlider(displayPos)),
        if (_hasProgram) ...[
          const SizedBox(width: 8),
          ExcludeSemantics(
            child: Text(
              _formatEpochTime(context, _rangeEnd),
              style: const TextStyle(color: Colors.white70, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildVerticalLayout(int displayPos) {
    const style = TextStyle(color: Colors.white70, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildSlider(displayPos),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: .spaceBetween,
            children: [
              ExcludeSemantics(
                child: Text(_formatEpochTime(context, _hasProgram ? _rangeStart : displayPos), style: style),
              ),
              if (_hasProgram) ExcludeSemantics(child: Text(_formatEpochTime(context, _rangeEnd), style: style)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSlider(int displayPos) {
    final positionFraction = _epochToFraction(displayPos);
    final normalizedDisplayPos = _normalizedEpoch(displayPos);
    final semanticsEnabled = widget.enabled && widget.onSeekEnd != null && _hasSeekableRange;
    final canIncrease = semanticsEnabled && normalizedDisplayPos < _seekEnd;
    final canDecrease = semanticsEnabled && normalizedDisplayPos > _seekStart;

    return FocusableWrapper(
      focusNode: widget.focusNode,
      onKeyEvent: widget.enabled ? widget.onKeyEvent : null,
      onFocusChange: widget.onFocusChange,
      borderRadius: 8,
      autoScroll: false,
      delegateFocusBorder: true,
      disableScale: true,
      child: Builder(
        builder: (context) {
          final slider = ClickableCursor(
            enabled: semanticsEnabled,
            // Eager claim: a touch that lands on the scrubber belongs to it
            // from pointer-down, so ancestor recognizers can't steal the drag
            // (#1302). A plain tap is onStart+onEnd, which seeks to the
            // tapped position.
            child: Semantics(
              label: t.videoControls.timelineSlider,
              slider: true,
              value: _semanticEpochValue(normalizedDisplayPos, isCurrent: true),
              increasedValue: canIncrease ? _semanticEpochValue(_semanticTarget(normalizedDisplayPos, 10)) : null,
              decreasedValue: canDecrease ? _semanticEpochValue(_semanticTarget(normalizedDisplayPos, -10)) : null,
              enabled: semanticsEnabled,
              onIncrease: canIncrease ? () => _semanticSeekBy(normalizedDisplayPos, 10) : null,
              onDecrease: canDecrease ? () => _semanticSeekBy(normalizedDisplayPos, -10) : null,
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                gestures: semanticsEnabled
                    ? <Type, GestureRecognizerFactory>{
                        EagerHorizontalDragGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<EagerHorizontalDragGestureRecognizer>(
                              () =>
                                  EagerHorizontalDragGestureRecognizer(debugOwner: this)
                                    ..dragStartBehavior = DragStartBehavior.down,
                              (instance) {
                                instance.onStart = (details) => _onDragStart(details, renderBoxSizeOf(context).width);
                                instance.onUpdate = (details) => _onDragUpdate(details, renderBoxSizeOf(context).width);
                                instance.onEnd = (_) => _onDragEnd();
                                instance.onCancel = _onDragEnd;
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
                        positionFraction: positionFraction,
                        bufferStartFraction: _hasProgram ? _epochToFraction(_seekStart) : null,
                        bufferEndFraction: _hasProgram ? _epochToFraction(_seekEnd) : null,
                        showFocusKnob: CardFocusScope.maybeOf(context) ?? false,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          return MouseRegion(
            onHover: (event) {
              final width = renderBoxSizeOf(context).width;
              if (width <= 0) return;
              final epoch = _fractionToEpoch((event.localPosition.dx / width).clamp(0.0, 1.0));
              if (_hoverEpoch != epoch) setState(() => _hoverEpoch = epoch);
            },
            onExit: (_) => setState(() => _hoverEpoch = null),
            child: Tooltip(
              message: _formatEpochTime(context, _hoverEpoch ?? displayPos, includeSeconds: true),
              excludeFromSemantics: true,
              child: slider,
            ),
          );
        },
      ),
    );
  }

  void _onDragStart(DragStartDetails details, double width) {
    setState(() {
      _isDragging = true;
      _dragPositionEpoch = _currentEpoch(widget.player.state.position.inSeconds);
    });
    _applyDrag(details.localPosition.dx, width);
  }

  void _onDragUpdate(DragUpdateDetails details, double width) {
    if (!_isDragging) return;
    _applyDrag(details.localPosition.dx, width);
  }

  void _applyDrag(double dx, double width) {
    if (width <= 0) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    setState(() {
      _dragPositionEpoch = _normalizedEpoch(_fractionToEpoch(fraction));
    });
  }

  /// Shared by onEnd and onCancel so an interrupted drag still finalizes.
  void _onDragEnd() {
    if (!_isDragging) return;
    final target = _normalizedEpoch(_dragPositionEpoch);
    setState(() => _isDragging = false);
    if (widget.enabled && _hasSeekableRange) widget.onSeekEnd?.call(target);
  }
}

class _LiveTimelinePainter extends CustomPainter {
  final double positionFraction;
  final double? bufferStartFraction;
  final double? bufferEndFraction;

  /// D-pad focus: draw the shared focus knob instead of the handle (#2383).
  final bool showFocusKnob;

  _LiveTimelinePainter({
    required this.positionFraction,
    required this.showFocusKnob,
    this.bufferStartFraction,
    this.bufferEndFraction,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final trackY = size.height / 2;
    const trackHeight = 8.0;
    final trackRadius = Radius.circular(trackHeight / 2);
    final posX = positionFraction * w;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(w / 2, trackY), width: w, height: trackHeight),
        trackRadius,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.15),
    );

    final bufferLeft = (bufferStartFraction ?? 0) * w;
    final bufferRight = (bufferEndFraction ?? 1) * w;
    if (bufferStartFraction != null && bufferRight > bufferLeft) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(bufferLeft, trackY - trackHeight / 2, bufferRight, trackY + trackHeight / 2),
          trackRadius,
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.5),
      );
    }
    final progressRight = math.min(posX, bufferRight);
    if (progressRight > bufferLeft) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(bufferLeft, trackY - trackHeight / 2, progressRight, trackY + trackHeight / 2),
          trackRadius,
        ),
        Paint()..color = Colors.red,
      );
    }

    if (showFocusKnob) {
      paintPlayerFocusKnob(canvas, Offset(posX, trackY));
      return;
    }

    // Handle thumb (pill shape matching HandleThumbShape)
    const thumbWidth = 4.0;
    const thumbHeight = 20.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(posX, trackY), width: thumbWidth, height: thumbHeight),
        Radius.circular(thumbWidth / 2),
      ),
      Paint()..color = Colors.red,
    );
  }

  @override
  bool shouldRepaint(covariant _LiveTimelinePainter oldDelegate) =>
      positionFraction != oldDelegate.positionFraction ||
      showFocusKnob != oldDelegate.showFocusKnob ||
      bufferStartFraction != oldDelegate.bufferStartFraction ||
      bufferEndFraction != oldDelegate.bufferEndFraction;
}
