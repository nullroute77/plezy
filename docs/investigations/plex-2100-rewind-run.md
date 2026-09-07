# Plex #2100: four small rewinds, September 7, 2026

The new log identifies Plezy 2.19.1 diagnostic commit `1ecca57`. The user
opened a channel, attempted two small rewinds (both failed), jumped roughly a
minute backward using the timeline, then attempted two more small rewinds
(first failed, second succeeded). This clarifies that the minute refers to a
timeline jump, not simply time spent watching.

This investigation and its opt-in experiment belong to `codex/fix-2100`.
The timeline/UI work remains in the separate `codex/plex-program-timeline`
checkout. No upstream issue comment or PR is authorized.

## Correlated attempts

Times are the log's local wall clock. Offsets are seconds from the unchanged
capture origin, 1788820135.570925. First segment means the first `.ts` filename
opened by the replacement demuxer; it is not an independently verified HLS
media-sequence number or broadcast timestamp.

| Action | Seek dispatch | Offset sent | First segment | Ready after dispatch | User result |
| --- | --- | ---: | --- | ---: | --- |
| Initial tune | 17:30:24.707 (open) | omitted | 00001.ts | 0.390 s | playing |
| Small rewind 1 | 17:30:33.296 | 90 | 00013.ts | 0.508 s | failed |
| Small rewind 2 | 17:30:40.696 | 85 | 00028.ts | 3.947 s | failed |
| Timeline jump | 17:30:52.509 | 31 | 00034.ts | 0.482 s | jumped back about a minute |
| Small rewind 3 | 17:31:01.889 | 28 | 00051.ts | 0.484 s | failed |
| Small rewind 4 | 17:31:19.930 | 34 | 00050.ts | 3.557 s | succeeded |

Relevant original log lines: 263–264, 371–372, 481, 648–649, 828–829
(requests); 290, 398, 507, 675, 855 (replacement segment opens).
Raw logs remain outside the repository; do not publish their URLs or identities.

## What this rules out for this run

All targets remained inside the reported capture bounds. Every seek decision
returned HTTP 200, and all five replacement opens reached source-qualified
readiness with `opened=true`. No stale source calibrated another generation.
The four relative targets were ten seconds behind the application's raw clock
when the button was pressed. The final offset increases from 28 to 34 because
roughly 17 seconds of playback elapsed before that rewind; it is not a forward
seek relative to the displayed position at the time of the click.

Every first-frame position was near zero (15–64 ms). The provisional clock
therefore mapped the requested epoch to whatever frame actually appeared.
Heartbeats subsequently supplied a playback origin roughly 1–2 seconds before
the requested epoch. Those corrections were small compared with the changing
segment numbers. Neither readiness nor that origin proves the requested
broadcast frame was rendered.

## HLS startup hypothesis and native reproduction

FFmpeg n8.0.1 selects a live playlist's third-from-last segment by default
(`live_start_index=-3`). MPV v0.41.0 rebases the demuxer's start timestamp to
zero by default. Together, these can skip already-produced segments in Plex's
new offset-specific playlist while leaving Plezy's raw player clock near zero.
How many segments exist when the demuxer opens can vary between seeks.

Sources matching the Windows dependency pin:

- [FFmpeg n8.0.1 HLS demuxer](https://github.com/FFmpeg/FFmpeg/blob/894da5ca7d742e4429ffb2af534fcda0103ef593/libavformat/hls.c), `select_cur_seq_no` and `hls_options`.
- [MPV v0.41.0 rebasing option](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/DOCS/man/options.rst), `--rebase-start-time`.

Using the checksum-verified Windows x64 DLL from this checkout's
`mpv-build.lock.json`, a synthetic 20-segment live HLS playlist gave:

| Open on the same MPV instance | Demuxer start | Player position |
| --- | ---: | ---: |
| Default | 18.440 s | 0.000 s |
| File-local `live_start_index=0` | 1.440 s | 0.000 s |
| Default again | 18.440 s | 0.000 s |

This demonstrates 17 seconds of skipped content hidden by a zero player
position. The file-local option preserved the other demuxer option and was
restored on the following ordinary open. The native harness is
`scripts/diagnostics/probe_live_hls_start.py`; it uses synthetic local media
and needs no Plex connection or credentials.

This proves the mechanism on the shipped native library, not the exact landing
of the user's stream. The changing first-segment filenames are consistent with
it, including the successful final attempt, but the supplied log lacks playlist
contents, EXTINF durations, program date-times, and unrebased timestamps.
Do not convert filenames directly into measured seconds or call #2100 fixed.

## Opt-in experiment

`PLEX_LIVE_SEEK_HLS_FROM_START=true` makes native MPV opens with an explicit
server offset use the file-local `demuxer-lavf-o-append=live_start_index=0` option.
Ordinary initial live opens, ExoPlayer, and VOD retain their existing behavior.
This flag defaults to false and is enabled in the fork diagnostic workflow.
No request offsets, fastSeek/copyts settings, or clock anchors were changed.

Diagnostic builds also sample `demuxer-start-time` and the rebasing setting at
source readiness. Only numeric/boolean values are logged. Samples are dropped
if another open starts before the asynchronous reads finish; they do not change
the clock. Missing properties cannot prevent playback.

Repeat the same sequence on the new build with Direct Stream and subtitles off.
Export logs from that run and identify whether the actual content rewound at
each step. The `open` log must show `hlsFromStart=true` on the offset seeks.
Check the new `demuxer` samples and first segment opened after each seek.
If the content still lands incorrectly, obtain the corresponding media-playlist
snapshot/server evidence before changing clock arithmetic or adding delays.

## Validation of the experiment

- Native Windows probe against the pinned DLL: all three opens passed, including
  preservation of another demuxer option and restoration on the following open.
- 102 focused Dart tests passed with both diagnostic flags enabled (player open,
  live clock/source state, seek accumulation, and backend playback sessions).
- Full Flutter analysis passed with no issues; changed Dart formatting and
  `git diff --check` passed.
- Workflow security guard and its 11 regression tests passed.
- No live Plex runtime verification of this experiment has occurred yet.
