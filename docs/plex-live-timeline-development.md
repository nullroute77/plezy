# Plex Live TV timeline development (unsubmitted)

Status: the user is satisfied with the timeline before integration. The separate
MPV fix for #2100 merged upstream as PR #2282 (`d1925b89`) and is now integrated
into this branch with current upstream main. Previous-program tracking and
remote/keyboard previews are retained. Test the combined builds before preparing
any timeline PR; no new branch or PR is authorized. Broadcast timing remains
estimated. The earlier investigation notes below describe the pre-fix work.

Fork: nullroute77/plezy. Branch: codex/plex-program-timeline.
Starting SHA: 8238705d3e70add2ed32bbf4ae1af7bf96954e8c.
Only origin is writable; upstream push URL is disabled.

Presentation revision after user testing: Live TV now reuses the movie
TimelineSlider, including its rounded playhead, BufferRangePainter and hover
tooltip (formatted as program clock time). The playhead and buffered time before
it use the original Live TV red; buffered time after it stays gray. The channel
header shows the program title and duration beneath the channel name. A pending seek uses the
same preview thumb as movie seeking. Extra fallback/estimated/pending text and
elapsed/total labels are removed from the visible bar. Timing accuracy and
fallback metadata remain in the model and accessibility semantics; the uniform
thumb is not new evidence of confirmed playback. These requested presentation
changes supersede the initial distinct-marker design recorded below.

Buffer-refresh revision: Plex timeshift heartbeat snapshots now refresh every
two seconds, retaining the three-second startup grace period. Polls do not
overlap, so slow replies cannot arrive behind a newer poll and move its bounds
backwards. Freshness/UI ticks continue during an outstanding request, including
while paused. Other backends keep their ten-second interval. The shared slider
and painter are unchanged. Shading still reflects reported seekable bounds;
it is not extended to match an estimated playhead. Server snapshot granularity
and unvalidated playback anchors can therefore still produce a visual gap.

## Living plan

- [x] Fork, ownership, instructions, source and issue discovery.
- [x] Two read-only investigations reconciled; baseline commands attempted.
- [x] Shared epoch/window/validity contract and deterministic model tests.
- [x] Plex adapter and estimated-clock integration, preserving recovery.
- [x] Program-aware UI and session-local historical EPG retrieval.
- [x] Integrated tests, two-worker cross-review, diff review and commits.
- [x] Manual test guide and evidence/limitations report.
- [ ] Establish authoritative Plex broadcast timing and validate real content.

## Evidence and scope

Before PR #2282, the September 4 discussion reported af9fb3f fixed the
replacement MPV clock, but small near-live seeks still fail. September 7's
report confirms the later build still fails. Logs correlate requested offsets
with server origin changes; they do not contain raw capture/playback timing
payloads or a rendered-frame broadcast timestamp. No real tuner is available
in this workspace. Do not call synthetic clock tests a real-source diagnosis.

Starting flow: LiveSeekAccumulator debounces relative targets; player part
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
accuracy and active/last-known state. Confirmed playback selects a known program;
active estimated playback now selects a program in an explicitly estimated model
mode. A last-known position retains program context while reopening or failed,
without showing an active playhead. Remote/keyboard and skip-button seeks opt into
destination-program preview; that preview stays until the accumulated seek
settles and never changes the actual playback clock. Mouse scrubs, touch double-tap skips,
and return-to-live do not opt in. Missing preview history uses the buffer range.
Missing history or stale schedule data falls back to live metadata, then a buffer
view, then unavailable state. Out-of-window thumbs are hidden.

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
workers performed cross-review; there is no third independent reviewer. Human review
and testing have not been reported for this branch.

## Integrated review and known limits

Frozen review snapshot: e7a1a8c47a7ca921c0a1f8de6a9d97a0f9b837bd.
The same two workers performed read-only cross-review, primarily outside their
own code. Six unique findings were accepted: subtitle transition ownership,
stale buffer execution, watch-from-start offset bypass, empty EPG responses
marking history fresh, corrected schedule ends retaining obsolete entries, and
same-target pending skips unnecessarily superseding readiness. Fixes pass the
source-switch lease explicitly, centralize fresh offset bounds (30 seconds),
route initial selection through the adapter, conservatively mark empty channel
responses stale, replace corrected airings by identity/start, and preserve
same-target operations. Explicit backend return-to-live remains possible with
stale bounds; no offset is sent for that operation. Additional main review
preserves retry/session ownership and marks backwards same-source timestamp
jumps over two seconds as discontinuities. Forward gaps remain ambiguous.

Important: this is a tested foundation and safer seek implementation, NOT a
verified repair of #2100's remaining real-content near-live failure. Neither
Plex timeStamp nor request-plus-first-position is proven to identify the
rendered broadcast frame. Both remain estimated. The initial implementation
required confirmed timing for program selection, so Plex could never select an
earlier program even when historical EPG was loaded. The timeline revision now
uses active estimates for guide selection without upgrading their accuracy.
This makes previous-program display possible before the separate #2100 repair,
but transitions can be early/late if the underlying estimate is wrong. Missing
history still falls back to the live program. LIVE now uses active estimated or
confirmed playback within 15 seconds of a fresh live edge; it does not upgrade
clock accuracy. No new labels, marker shapes or widget implementation are added.

The next diagnostic step requires a real source: correlate rendered content
with source-specific server timing and HLS segment program-date-time, where
available. Do not apply a guessed tuner latency, change fastSeek/copyts, or
claim an exact requested landing. New debug entries include only local stream
and source IDs, requested/effective epochs, capture origin, and player seconds;
no authenticated URLs or tokens are added. The non-native player has no
load-bound source ID and keeps only a clearly unverified estimate after open;
its source-event guarantees remain weaker than native MPV. No new native
framework was introduced to disguise that gap.

A capture snapshot is not extrapolated with device time. After 30 seconds
without a fresh capture response, offset controls disable. Pause may put the
playhead outside the retained buffer without a jump: resuming still-valid
media is allowed. If actual playback fails, the existing retry/degradation
ladder re-tunes and returns to live, reports failure if recovery fails, and
reconciles only an estimated new position. A failed URL lookup preserves the
active mapping; failure after replacement preserves last-known position.
Pending timeouts clear the failed target while retaining the existing late
readiness registration. Elapsed heartbeat time uses Stopwatch, including
paused elapsed time as the prior heartbeat did. Device now is only a guide
fallback/lookup input, never confirmed playback or an absolute seek target.

EPG retention is session-local and bounded to the requested buffer/playback
range plus six hours ahead. No persistent EPG history, Jellyfin/Emby timeshift,
backend port, general session framework, native change, or dependency upgrade
was introduced. Empty/partial Plex responses cannot perfectly distinguish
missing history from provider failure; empty channel data is conservatively
stale. Schedule corrections for the same identity/start replace older bounds.

## Validation record

SDK blockage was resolved without system installation: checked out official
Flutter tag 3.47.1 at 6655482ec06e547f90abf8ae7590466f4415978d into /tmp,
then unpacked Ubuntu's unzip package locally to bootstrap it. Runtime: Flutter
3.47.1, Dart 3.13.1, Linux/WSL. No native application was built or tuner used.
Repository/root and vendored wakelock_plus dependencies were installed exactly
as CI specifies (`flutter pub get` and, inside packages/wakelock_plus,
`flutter pub get --enforce-lockfile --no-example`). No lockfile changes retained.

On the pristine starting checkout after dependency setup:

- `flutter analyze`: passed. Before vendored dev-dependency setup, 49 diagnostics.
- `bash scripts/run_tests.sh -j 4`: 7,036 passed, 6 skipped.
- `bash scripts/codegen.sh --check`: passed.
- `dart format --output=none --set-exit-if-changed .`: flagged 44 existing files.

On the first integrated snapshot:

- `flutter analyze`: passed; `dart run scripts/checks/check_analyzer.dart`: passed.
- `bash scripts/run_tests.sh -j 4`: 7,062 passed, 6 skipped.
- `bash scripts/codegen.sh --check`: passed.
- Translation hygiene was incomplete until the final locale-placeholder repair;
  the final failure and successful rerun are recorded in the validation note.
- `dart format .`: succeeded; the 44 unrelated formatter-only changes were
  restored. CI's non-generated lib/test formatting scope passed.
- Focused commands used `flutter test -j 4` with the timeline model/widget,
  guide, accumulator, Plex adapter, clock state, retry and transient feedback
  test paths. Initial run: 105 passed. After expanded regressions: two timeout
  expectations were corrected for intentionally cleared pending state; 96
  tests in the subsequent affected-file run passed.
- `live_pending_playback_regression_test.dart` was run unchanged on both trees:
  starting code fails (expected last playback 1010, got pending target 1500),
  changed code passes. This proves the pending-state defect, not actual #2100
  content landing. Fake HTTP Plex tests additionally exercise adapter inputs,
  stream readiness, nonzero time-pos, differing origin, moving buffer and
  A/B/A or newer-operation rejection through runLiveTvSeek.

Final post-review check results are recorded in the companion validation note.
Native formatting/checks and Maestro were not run: no native files changed,
and disposable Jellyfin E2E cannot validate real Plex tuner content timing.

## Manual build and test guide

### Download GitHub Actions test builds

The fork-only **Live TV test builds** workflow (`windows-portable-test.yml`)
builds Windows x64 portable and Android TV ARM64 APKs in parallel on pushes to
`codex/plex-program-timeline`. Open your fork's Actions tab, select that workflow
and the run for the commit you want, then download the successful job's artifact:

- `plezy-windows-x64-portable-test-<commit>`: extract the whole ZIP into a folder
  and run `plezy.exe`; keep its DLLs and data folder together.
- `plezy-androidtv-arm64-test-<commit>`: extract and sideload
  `plezy-androidtv-arm64-test.apk` on a TV with a 64-bit Android OS. Plezy's
  existing Android TV detection and TV launcher apply; there is no TV flavor.
  This APK uses a test signing key and cannot update an official installation.
  Consecutive test builds can update each other while the cached key is retained;
  cache eviction changes the key and requires reinstalling. Uninstalling deletes
  local app data. No production signing secrets are used.

Each `TEST-BUILD.txt` records the exact commit. Artifacts expire after 14 days; use **Re-run all jobs**
on an existing run to rebuild. The new workflow does not need to be merged into
main to run on push. GitHub's manual dispatch UI may require it on the default
branch, so use the push trigger or rerun for this feature branch.

Both jobs use the pinned Flutter SDK, disable automatic update checks and Sentry,
and upload Actions artifacts. The Windows job uses the patched Windows engine.
Neither creates a GitHub release or deploys. Portable packaging does not
imply isolated application settings; record the build identity when reporting
results. The existing release workflow and its main-branch restriction remain
unchanged.

### Build locally

Use your fork branch on Windows with Flutter 3.47.1, Visual Studio's Flutter
Windows build prerequisites, and Git Bash for repository shell scripts.
`flutter doctor -v` identifies missing platform dependencies. Use the project's
pinned native dependencies; do not substitute an older installed MPV DLL.

```text
git clone --branch codex/plex-program-timeline https://github.com/nullroute77/plezy.git
cd plezy
flutter pub get --enforce-lockfile --no-example
# In Git Bash:
bash scripts/codegen.sh
# In PowerShell (matches the Windows CI prerequisite):
flutter precache --windows
.\windows\tool\install-patched-engine.ps1
flutter build windows --release
```

For Android, use Flutter's Android SDK/JDK prerequisites and `flutter build apk
--release`; test both the selected player and native MPV where available.
Before testing, record platform/device, `git rev-parse HEAD`, Plezy version,
Plex server version, active player/MPV version, source type and stream settings.
No version or setup is inferred from the older issue report for this branch.

1. Join midway through a long scheduled program. Expect the channel name in the
   player header with the program title and scheduled duration beneath it, using
   the episode subtitle style. The timeline shows full start/end labels, the
   movie timeline's buffered intersection, and its rounded playhead in the
   original Live TV red. Buffered time before the displayed playhead is red;
   buffered time after it stays gray, and gaps/unavailable time stay unfilled.
   Hover or scrub to see program clock time with seconds (for example, 2:30:45 PM
   or 14:30:45); start/end labels remain concise. Estimates
   and pending positions use the same thumb; underlying accuracy is unchanged.
2. Scrub before/after availability: expect the nearest valid grid point within
   the shown program. At an empty intersection, scrubbing disables. Relative
   skips use the entire buffer, including across program boundaries.
3. Repeat small backward/forward skips rapidly while reopening. Expect one
   preview thumb accumulating effective targets without changing its shape;
   check actual content, especially 10/15/20/30s rewind near live (#2100).
4. Return to live from inside and before the current program, including during
   a pending seek. Expect offsetless backend live operation and latest intent
   ownership; actual landing remains estimated until stronger evidence exists.
5. Pause/resume, then pause beyond retention. Expect advancing highlighted
   bounds without a fabricated playback jump. Failure/recovery must be visible;
   old targets must not be reported as reached. After heartbeat loss, offset
   controls disable; explicit live operation remains available.
6. Use remote/keyboard seeks across earlier and later programs in the buffer.
   Expect title, duration, bounds, and the preview thumb to follow the target
   immediately and remain there while its replacement stream opens. Reverse
   direction repeatedly. On failure/cancellation, expect the last playback
   program again; after success, actual playback takes over without a flash of
   the old program. Mouse dragging retains the displayed program. Play forward
   across its end: the next program owns the exact boundary
   according to the active estimate. Compare with actual content and record any
   early/late change separately. Missing Plex history remains a real limitation.
7. Change A -> B -> A during a pending seek, and during recovery. Old opens and
   state must not take ownership. Toggle Plex burn subtitles while behind live
   and after a return-to-live; the existing source-switch lease must still work.
8. Safely induce URL/reopen failure if possible. Expect failure feedback,
   cleared pending state and retained active or last-known playback as applicable.
   Run long enough to see rolling windows and schedule corrections.

Share sanitized timing logs and content observations from the same run. Do not
include tokens, complete stream URLs, private server addresses or source details.
No human test or review of this branch is claimed until you report it.

## Possible later submission boundaries

No upstream submission is authorized or prepared remotely. The pending-state
and stale-owner repairs are distinguishable defects; the absolute-time adapter
and shared model support both those controls and the program UI. Program
presentation, fallback wording and conservative accuracy behavior are deliberate
product choices that need maintainer agreement before eventual submission.
One or multiple PRs can be considered after real-source timing is established;
forcing a split now would obscure the shared contract dependencies. The issue
report does not approve this design, and successful automated checks do not
establish upstream acceptance. Jellyfin/Emby can later supply the optional
absolute-time capability after their actual seek/timestamp semantics are tested.

The recheck found three follow-up cases, now corrected: retry finalization must
release its own status even when seek intent becomes stale, paused playback
must not inherit a last-open-live hint for subtitle preservation, and changing
pending live to an offset operation must notify cancellation even when its
numeric target is unchanged. Retry ownership now lives in LiveTvSessionState;
a previous retry cannot clear a newer one's flag. Offset and subtitle inputs
are unavailable during recovery. Subtitle changes preserve the active epoch
estimate, including after pause. The obsolete atLiveEdge mutable flag was
removed: its former UI role belongs to the snapshot, and its subtitle role
now uses the active estimate. A helper-path deferred recovery regression covers
the stale result/finalizer sequence. Same-source forward timestamp gaps remain
ambiguous; only clear backward discontinuities are invalidated automatically.
