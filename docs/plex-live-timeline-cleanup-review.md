# Live TV changes: leftover-code review

Read-only subagent audit of `8238705d3e70add2ed32bbf4ae1af7bf96954e8c` through
`56e49be193373129dfa37b21a219586771afef0b`, independently checked against callers
by the main agent. The initial review was read-only. All five candidates below
have now been removed at the user's request; file/line references describe the
audited revision, before removal. Existing position tests now exercise
`playbackPosition(position).epoch` directly without a zero fallback or rounding
wrapper. Existing retry and seek regressions are retained.

Cleanup validation: 58 focused session/seek/retry tests passed; the full suite
passed 7,084 with 6 skipped. Analysis, changed-Dart formatting, code generation
and strict translation hygiene passed. Logs: `/tmp/plezy-cleanup-*.log`.

Completed low-severity cleanups (original findings):

1. `lib/screens/video_player/live_tv_session_state.dart:54,381`:
   `playbackStartTime` is write-only. Reporting now uses `playbackElapsed`.
   Removed this field and assignment; the separate Discord timestamp is unrelated.
2. `lib/screens/video_player/live_tv_session_state.dart:330`:
   Removed `epochForPosition()`, a legacy wrapper used only by tests. Those tests
   now inspect `playbackPosition(position).epoch`, preserving their pending/source
   regressions and asserting the exact fractional epoch where applicable.
3. `lib/services/live_seek_accumulator.dart:88`:
   No caller sets the optional `seekTo(..., live: true)` argument. Return-to-live
   uses `jumpToLive()`. Removed the optional argument and set `_pendingLive` to
   false for absolute scrubs, retaining the pending ownership machinery.
4. `lib/screens/video_player/parts/live_tv.dart:195,236`:
   The post-await success condition is unreachable: `runLiveStreamRetry` calls
   `onFinished` in its `finally`, which releases the retry owner required by
   `isCurrent()`. Successful adoption already clears `retryFailed` at line218.
   Removed the final conditional and the unused `result` binding.
5. `lib/screens/video_player_screen.dart:426`:
   The old live-edge threshold constant's four-line documentation remains above
   an unrelated route guard. Removed the orphaned comment.

Keep the six timeline translation keys (used by accessibility), previous-program
guide history, accuracy/pending/stale distinctions, and shared slider/painter
options. These all have current consumers. `liveChannelName` plumbing and
`canTimeShift` were already unused in the baseline and are outside this review's
branch-induced cleanup scope.

Documentation also needs to distinguish historical white-playhead/frozen-code
notes from current behavior. The build documentation update addresses the current
presentation introduction; historical validation runs remain useful evidence.
