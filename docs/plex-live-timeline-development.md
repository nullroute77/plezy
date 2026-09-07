# Plex Live TV timeline development (unsubmitted)

Status: implementation in progress; not ready for real-source validation.

Fork: nullroute77/plezy. Branch: codex/plex-program-timeline.
Starting SHA: 8238705d3e70add2ed32bbf4ae1af7bf96954e8c.
Only origin is writable; upstream push URL is disabled.

## Living plan

- [x] Fork, ownership, instructions, source and issue discovery.
- [x] Two read-only investigations reconciled; baseline commands attempted.
- [ ] Shared epoch/window/validity contract and deterministic model tests.
- [ ] Plex adapter and clock-state integration, preserving recovery.
- [ ] Program-aware UI and session-local historical EPG retrieval.
- [ ] Integrated tests, two-worker cross-review, diff review and commits.
- [ ] Manual test guide and evidence/limitations report.

## Evidence and scope

Issue #2100 remains open. September 4 discussion reports af9fb3f fixed the
replacement MPV clock, but small near-live seeks still fail. September 7's
report confirms the later build still fails. Logs correlate requested offsets
with server origin changes; they do not contain raw capture/playback timing
payloads or a rendered-frame broadcast timestamp. No real tuner is available
in this workspace. Do not call synthetic clock tests a real-source diagnosis.

Current flow: LiveSeekAccumulator debounces relative targets; player part
live_tv.dart resolves an integer capture offset through streamUrlAt, reopens
MPV, then LiveTvSessionState binds clock readiness to the load's source ID.
The source-ID machinery (baa31742) handles event/reply ordering and obsolete
opens. It must be retained. Request-minus-first-position is only an estimate;
the top-level playback timeStamp assumption (12a38080) is not independently
validated by the available source logs. Never invent a latency subtraction.

The demonstrable stale-session continuation in _seekLivePosition and false
presentation of pending seeks can be corrected independently of program UX.
The full scheduled program bar is an additional product choice. The shared
model earns its place by supplying the same window/seek/playback distinctions
to Plex controls; no other backend timeshift adapter is in scope.

## Contract

Absolute times are UTC epoch seconds with fractional precision. EPG bounds
are half-open; backend target windows are inclusive grids with restricted
endpoints removed by the adapter. Relative seeks use the whole target window;
scrubs use its intersection with the displayed program. Pending targets never
replace playback. Playback has explicit unknown/estimated/confirmed/stale
accuracy and active/last-known state. Only confirmed playback selects a known
playback program. Missing evidence uses explicitly identified live metadata,
then a buffer view, then unavailable state. Out-of-window thumbs are hidden.

EPG uses existing fetchSchedule(from,to), scoped with existing channel matching,
retained only in session memory and refreshed over the buffer. Plex may no
longer supply expired schedule data. Overlaps prefer latest start, earliest end,
then stable identity/title. Device now is allowed for guide fallback selection,
never to move confirmed playback. Local elapsed measurement uses Stopwatch.

## Baseline

Clean starting tree. Commands attempted before substantive edits:

- dart format --output=none --set-exit-if-changed .: blocked, dart missing.
- flutter analyze: blocked, flutter missing.
- scripts/run_tests.sh: blocked, flutter missing (auto-selected 24 jobs).
- scripts/codegen.sh --check: blocked, dart missing.

Pinned Flutter 3.47.1 Linux archive and release manifest downloads returned
HTTP 404 in this environment. No unrelated toolchain/dependency changes made.

## AI disclosure / review

Main agent: GPT-6-based Codex, selected settings unchanged. Exactly two worker
spawn calls selected gpt-6-astra with reasoning_effort=low using supported tool
parameters. No custom role overrides found; workers expose no independent
runtime settings introspection. No global configuration changed. Worker 1:
Plex timing/adapter; worker 2: UI/EPG investigation and control presentation.
Both prohibited from further delegation and repository operations. The same
workers will cross-review; there is no third independent reviewer. Human review
and testing have not been reported for this branch.
