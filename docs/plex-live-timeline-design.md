# Plex timeline design note — unsubmitted fork draft

This draft separates requested seeks from playback and adds a shared scheduled
program timeline. The separate MPV fix for
[#2100](https://github.com/edde746/plezy/issues/2100) merged as
[PR #2282](https://github.com/edde746/plezy/pull/2282) (`d1925b89`) and is now
integrated here. Offset seeks and watch-from-start explicitly start MPV at the
first available HLS segment; offsetless live opens keep MPV's defaults. This
does not promote the timeline's estimated broadcast clock to confirmed accuracy.
The user tested the fix separately; the combined timeline builds need device testing.

One defect is reproduced deterministically: the starting session state reports a
pending target of 1500 as playback while actual last playback is 1010. The same
regression fails on the starting commit and passes here. Fake Plex HTTP/reopen
tests also cover offset translation, nonzero player timestamps, differing server
origin and stale completions. Those tests establish application behavior, not the
physical content landing of the reported tuner stream.

The shared contract uses fractional UTC epoch seconds. Scheduled programs are
half-open intervals. The backend supplies an inclusive grid of allowed seek
targets. Pending, active playback, last-known playback and live-edge evidence
remain distinct, with explicit unknown/estimated/confirmed/stale accuracy. Only
confirmed playback selects a known playback program. Active estimates may select
guide metadata in an estimated program mode, and last-known positions retain
program context during reopen/failure. Neither changes playback accuracy.
Remote/keyboard and skip-button program previews select the destination airing while
the seek is pending, including source readiness. Mouse scrubs retain their
displayed-program behavior. Missing/stale preview guide data uses the buffer
range so the target remains visible. Device time selects guide fallback metadata;
it never advances confirmed playback. Local elapsed time uses
Stopwatch. The existing source-ID readiness, transition leases and retry ladder
are retained, with checks after asynchronous boundaries and owned retry cleanup.

Plex translates absolute targets at an optional timeshift capability boundary;
shared controls no longer calculate capture offsets. The adapter uses integer
offsets from ceil(minOffset) through ceil(maxOffset)-1, retaining fractional
capture origin. Excluding the latest captured endpoint is conservative; available
evidence does not prove every selected offset lands exactly or is complete.
Return-to-live uses the offsetless backend operation. Both server-origin and
request/first-player-time mappings remain estimates. Establishing a validated
broadcast anchor is the outstanding dependency for confirmed content alignment.
Timeline program selection and the LIVE indicator may use active estimates;
LIVE applies Plezy's 15-second tolerance against fresh live-edge timing without
upgrading the broadcast clock's accuracy. Pending targets do not establish LIVE.

The deliberate UX change shows the entire scheduled program, unavailable portions
and the seekable intersection. Relative skips cross program boundaries using the
whole buffer; scrubbing stays within the displayed intersection. Following user
testing, the bar reuses the movie TimelineSlider, buffer colors and hover tooltip.
Playback and pending previews share its rounded thumb; extra status and elapsed
labels are removed. Accuracy remains explicit in state and accessibility semantics.
Missing playback metadata falls back to live-program metadata, then a buffer
view, then unavailable. Out-of-window
playheads are hidden instead of pinned. Existing schedule retrieval is refreshed
over retained content and cached only for this session; no persistent EPG system
is added. Real Plex can select previous-program metadata from its active playback
estimate; missing history or stale guide data still falls back to live metadata.

The abstraction serves current Plex and shared UI needs. Jellyfin/Emby retain
their existing capabilities; their timeshift adapters are deferred until their
actual timing contracts are tested. No native subsystem or dependencies change.

Current sequencing: test the timeline together with the merged #2100 fix on this
existing branch. Previous-program tracking is retained. Create no new timeline
branch or PR until the user approves.
Possible later submission boundaries are the demonstrable pending/ownership
repairs, the absolute-time contract and adapter migration, and the program UI.
Their shared-control dependencies should determine the eventual split after
real-source validation. Maintainer agreement would help on endpoint policy,
accuracy/fallback wording and full-program presentation. The issue does not
approve the redesign. No upstream timeline PR, issue, comment or review request was made.

AI disclosure: development/integration used GPT-6-based Codex with its selected
settings unchanged. Exactly two reused workers were explicitly spawned with
`model=gpt-6-astra` and `reasoning_effort=low`; they handled Plex timing and UI/EPG,
then cross-reviewed. Independent runtime model introspection was unavailable;
no stronger metadata claim or human testing/review is made.
