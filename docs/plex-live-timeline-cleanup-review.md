# Live TV changes: leftover-code review

Read-only subagent audit of `8238705d3e70add2ed32bbf4ae1af7bf96954e8c` through
`56e49be193373129dfa37b21a219586771afef0b`, independently checked against callers
by the main agent. No playback code was changed as part of this review.

Five low-severity cleanup candidates:

1. `lib/screens/video_player/live_tv_session_state.dart:54,381`:
   `playbackStartTime` is write-only. Reporting now uses `playbackElapsed`.
   Remove this field and assignment, leaving the separate Discord timestamp alone.
2. `lib/screens/video_player/live_tv_session_state.dart:330`:
   `epochForPosition()` is a legacy wrapper used only by tests. Remove it and
   update those tests to inspect `playbackPosition(position).epoch`, preserving
   their pending/source regressions and intended rounding expectations.
3. `lib/services/live_seek_accumulator.dart:88`:
   No caller sets the optional `seekTo(..., live: true)` argument. Return-to-live
   uses `jumpToLive()`. Remove the optional argument and set `_pendingLive` to
   false for absolute scrubs; keep the pending ownership machinery.
4. `lib/screens/video_player/parts/live_tv.dart:195,236`:
   The post-await success condition is unreachable: `runLiveStreamRetry` calls
   `onFinished` in its `finally`, which releases the retry owner required by
   `isCurrent()`. Successful adoption already clears `retryFailed` at line218.
   Remove the final conditional and the unused `result` binding.
5. `lib/screens/video_player_screen.dart:426`:
   The old live-edge threshold constant's four-line documentation remains above
   an unrelated route guard. Remove the orphaned comment.

Keep the six timeline translation keys (used by accessibility), previous-program
guide history, accuracy/pending/stale distinctions, and shared slider/painter
options. These all have current consumers. `liveChannelName` plumbing and
`canTimeShift` were already unused in the baseline and are outside this review's
branch-induced cleanup scope.

Documentation also needs to distinguish historical white-playhead/frozen-code
notes from current behavior. The build documentation update addresses the current
presentation introduction; historical validation runs remain useful evidence.
