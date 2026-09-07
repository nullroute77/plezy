import 'dart:async';

import '../../media/live_tv_support.dart';

/// Poll capture metadata without overlapping requests. The caller handles
/// report failures and owns cancellation/session identity. Keep the initial
/// three-second grace period: an immediate Plex heartbeat can create a second
/// transcode before the first stream has stabilized.
Timer startLiveTimelinePolling({
  required Duration interval,
  required bool Function() isCurrent,
  required Future<void> Function() report,
  required void Function() onTick,
}) {
  var ready = false;
  var inFlight = false;
  late final Timer timer;

  Future<void> tick() async {
    if (!timer.isActive || !isCurrent()) return;
    onTick();
    if (inFlight) return;
    inFlight = true;
    try {
      await report();
    } finally {
      inFlight = false;
    }
  }

  timer = Timer.periodic(interval, (_) {
    if (ready) unawaited(tick());
  });
  Future<void>.delayed(const Duration(seconds: 3), () {
    ready = true;
    return tick();
  });
  return timer;
}

/// Sends one live-TV timeline report and commits what it learned only while
/// the dispatching session and scheduling generation still own the screen.
Future<void> runLiveTimelineReport({
  required LiveTvPlaybackSession requestSession,
  required int requestGeneration,
  required String state,
  required int positionMs,
  required LiveTvPlaybackSession? Function() currentSession,
  required int Function() currentGeneration,
  required bool Function() isMounted,
  required void Function(LiveTimelineUpdate update) commit,
}) async {
  final update = await requestSession.reportTimeline(
    state: state,
    positionMs: positionMs,
    durationMs: requestSession.program.durationMs ?? 0,
  );
  if (update == null ||
      state == 'stopped' ||
      !isMounted() ||
      currentGeneration() != requestGeneration ||
      !identical(currentSession(), requestSession)) {
    return;
  }
  commit(update);
}
