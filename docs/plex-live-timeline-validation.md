# Plex timeline validation — fork draft

Date: September 7, 2026. Account: `nullroute77` (GitHub ID 248068038).
Fork: <https://github.com/nullroute77/plezy>.
Branch: `codex/plex-program-timeline`.
Starting commit: `8238705d3e70add2ed32bbf4ae1af7bf96954e8c`.
Frozen code tested: `bb14f7274316cba76bb72ffc9f05ea453a84499a`.
Subsequent changes only add required empty translation placeholders and documentation;
`dart run slang` after adding placeholders produced no additional Dart changes.
The final delivery SHA and verified push status are in the task's final report.

This is a development draft for inspection and real-source diagnosis. #2100's
remaining content-position failure and authoritative Plex broadcast mapping are
unresolved. Automated success does not make the requested repair complete.

Later presentation revision: user notes requested the existing movie timeline
styling and removal of visible diagnostic labels. Live TV now uses TimelineSlider
and BufferRangePainter directly, with a stable rounded thumb for active/pending
positions and a clock-time hover tooltip. The initial marker assertions described
below are historical; revised widget tests cover shared styling, hover, clamped
scrubbing, unchanged playback semantics during pending seeks and cancellation
when the program changes mid-drag. Model accuracy remains unchanged.

Presentation revision checks: `flutter test -j 4 test/widgets/live_timeline_bar_test.dart
test/widgets/video_controls_test.dart` passed 114 tests; `bash scripts/run_tests.sh -j 4`
passed 7,073 with 6 skipped. `flutter analyze`, formatting of the three changed Dart
files, `bash scripts/codegen.sh --check` and strict translation hygiene all passed.
Logs for these runs are `/tmp/plezy-timeline-style-*.log`. The preceding x64 portable
workflow succeeded for `e548622b20046232045531e1c9a8e3d5d4fe08f2`; pushing this
revision starts a separate build containing the requested presentation changes.

Buffer-refresh revision: Plex timeshift polling changed from ten to two seconds,
with the three-second startup grace period retained and overlapping polls skipped.
The slider/painter and actual seek bounds are unchanged. Deterministic polling
and Live TV widget tests passed 19 cases; the full suite passed 7,076 with 6
skipped. Analysis, changed-Dart formatting and code generation passed. Logs are
`/tmp/plezy-buffer-refresh-*.log`. This reduces stale snapshot delay but does not
prove an estimated playback position belongs inside the reported capture window.

Hover-seconds revision: the existing clock formatter optionally includes seconds
for Live TV hover/scrub tooltips; program bounds retain minute labels. The shared
tooltip accounts for rendered label width so longer clock strings stay inside
the track. Formatter, Live TV and movie-control tests passed 149 cases, covering
12/24-hour output, second-by-second hover updates, clamped scrub labels and the
right edge. The full suite passed 7,078 with 6 skipped; analysis, formatting and
code generation passed. Logs are `/tmp/plezy-hover-seconds-*.log`.

Previous-program selection revision: 51 focused model/guide/widget/Plex tests
passed. The fake Plex test exercises historical EPG query parameters and parsing,
seek resolution, nonzero source readiness and estimated previous-program bounds.
The widget test checks title/start/end changes, no pending-target program switch,
last-known context after failure and forward playback over the exact boundary.
The full suite passed 7,081 with 6 skipped; analysis, formatting and code generation
passed. Logs are `/tmp/plezy-history-program-*.log`. Production changes are confined
to the timeline selector and its explicit estimated/last-known display modes;
Plex clock mapping, seek transport and slider rendering are unchanged.

## Environment and baseline

Flutter 3.47.1, Dart 3.13.1, Linux/WSL2 (kernel
6.18.33.2-microsoft-standard-WSL2). The SDK was checked out under `/tmp` at official
Flutter tag commit `6655482ec06e547f90abf8ae7590466f4415978d`. Initial baseline
commands were blocked because no SDK was installed. Archive/manifest downloads
returned 404; a local extracted unzip package enabled the SDK bootstrap. No system
installation, project toolchain upgrade or dependency changes were retained.

The main agent later repeated baseline checks in a detached checkout of the exact
starting commit. Root `flutter pub get` and, inside `packages/wakelock_plus`,
`flutter pub get --enforce-lockfile --no-example` matched CI dependency setup.
The initial 49 analyzer diagnostics disappeared after that vendored dependency
setup. Baseline: analyze and codegen passed; 7,036 tests passed, 6 skipped.
Baseline translation hygiene also passed.

`dart format --output=none --set-exit-if-changed .` identified 44 existing files
outside the changed implementation. The requested `dart format .` was run on the
branch, and those unrelated formatting edits were restored. The CI formatting
scope (non-generated Dart in lib/test) passes with zero changed files. Whole-tree
format cleanliness is therefore still a known baseline limitation.

## Final checks

All commands ran locally, using the pinned SDK on PATH; no remote CI dispatched.

| Command | Result |
| --- | --- |
| `bash scripts/run_tests.sh -j 4` | 7,069 passed, 6 skipped on frozen code |
| `flutter analyze` | No issues |
| `dart run scripts/checks/check_analyzer.dart` | Passed, zero allowed diagnostics |
| CI non-generated lib/test `dart format --output=none --set-exit-if-changed` | 1,469 files, zero changed |
| `bash scripts/codegen.sh --check` | Passed on frozen code; rechecked after placeholders |
| `python3 scripts/checks/clean_translations.py --check --strict` | Passed after final repair |
| `bash scripts/ci_guard_checks.sh` | Passed with pinned SDK on PATH |
| `dart run scripts/checks/check_icon_consistency.dart` | Passed, 864 non-generated files |

The formatting check supplied every non-generated Dart file under `lib` and
`test` to `dart format --output=none --set-exit-if-changed`, equivalent to CI's
`find lib test -name '*.dart' ! -name '*.g.dart' ! -name '*.freezed.dart' -type f -print0`
piped into `xargs -0 -r dart format --output=none --set-exit-if-changed`.
The first additional CI-guard invocation omitted the local SDK PATH and stopped
at its icon-checker tests with `dart` missing; rerunning with PATH fixed passed.
Release/upload text in that guard log comes from unit-test fixtures, not an
actual release or upload operation.

The frozen translation check initially failed: each of 21 non-English locales
lacked the six new keys. `python3 scripts/checks/clean_translations.py --clean`
added only empty placeholders, matching the existing English fallback policy.
`dart run slang` made no Dart changes. The strict rerun passed. No translated
wording or unrelated localization cleanup is claimed. Code generation emits an
SDK/analyzer language-version warning but exits successfully; dependencies were
not upgraded to silence it.

Test coverage includes half-open program selection, historical guide ownership,
overlap/gap/fallback states, program/buffer intersections, labels and distinct
pending/estimated/confirmed markers; full-buffer relative skips, quantized scrubs,
coalescing, live supersession and moving bounds; Plex adapter/reopen readiness,
nonzero timestamps, differing origins, failed/late opens, A/B/A and source IDs;
subtitle/recovery ownership and retry finalizers. Existing shared/VOD and backend
tests ran in the full suite. New helper tests do not establish tuner behavior.

The unchanged `test/screens/video_player/live_pending_playback_regression_test.dart`
fails against starting behavior (expected playback 1010, actual pending 1500) and
passes here. Fake HTTP tests in `test/services/plex_live_tv_support_test.dart`
exercise the adapter through `runLiveTvSeek` and session readiness. Focused runs
used `flutter test -j 4` with the affected paths, including timeline, guide,
accumulator, session state and controls tests. The final full run supersedes
intermediate totals and passed after all production review fixes.

Logs are local under `/tmp/plezy-frozen-*.log`,
`/tmp/plezy-final-*.log`, `/tmp/plezy-baseline-*.log`,
`/tmp/plezy-prefixed-regression.log` and `/tmp/plezy-fixed-regression.log`.
They are not committed artifacts and may disappear with temporary storage.

## Review and scope

Exactly two workers were reused for read-only cross-review of frozen snapshot
`e7a1a8c47a7ca921c0a1f8de6a9d97a0f9b837bd`, primarily outside their authorship.
Six initial findings were fixed: subtitle lease ownership, stale buffer execution,
initial watch-from-start offset bypass, empty EPG marked fresh, obsolete corrected
airings and same-target pending supersession. Recheck at
`bdfaf486bc203abb2c7c310804f203f3e2af222f` found retry finalizer ownership,
paused subtitle position and same-target live-to-offset notification cases.
All were corrected and rechecked at `bb14f7274316cba76bb72ffc9f05ea453a84499a`.
The workers reported no remaining concrete findings in those final targeted
cases. This was not a fresh third-agent review or independent hardware validation.

Main review retained existing source-ID/load readiness, cancellation, transition
leases and recovery; removed the obsolete mutable at-live hint after checking its
UI/subtitle callers; and kept Plex offsets in the adapter. Production growth
comes from the current contract, guide cache, seek execution and replacement UI,
not future backend adapters. The final file/line totals are in the delivery report.

## Outstanding evidence and manual testing

No native build, Maestro run, real tuner, credentials or player/server versions
were available for this branch. No human test is claimed. No native files changed;
disposable Jellyfin E2E cannot prove Plex source timing. Follow the
[build prerequisites and eight manual scenarios](plex-live-timeline-development.md#manual-build-and-test-guide)
and record actual platform, commit, server/player versions and source configuration.

The exact blocker is a validated relationship between active-stream player time
and rendered broadcast time. Supplied issue logs lack that evidence. Capture
sanitized request/effective target, capture origin, session/stream ID and player
timestamp alongside observed source content; correlate source/server/segment
timing where available. A requested target paired with the first player timestamp
is insufficient. Neither that anchor nor Plex's top-level timeStamp is confirmed.

Plex shows estimated playback. The subsequent previous-program revision permits
that active estimate to select historical guide metadata; it uses an explicit
estimated program mode and preserves last-known program context through reopen.
The earlier confirmed-only gate made previous-program selection impossible on
Plex and has been removed. Missing history/stale guide data still uses fallback.
Confirmed content alignment and confirmed at-live status are not yet achieved
on real Plex. Relative skips use the active estimate when no confirmed
mapping exists; their actual landing still needs validation. Backward same-source
timestamp jumps over two seconds invalidate mapping; forward gaps remain
ambiguous. Non-native player source-event identity is weaker. Missing historical
EPG can remain unavailable despite session-local historical retrieval.

The unsubmitted [design note](plex-live-timeline-design.md) records possible later
submission boundaries and AI disclosure. No upstream writes, PRs, releases or
deployments are authorized or performed. Jellyfin/Emby timeshift remains deferred.
