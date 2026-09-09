import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/live_tv_timeline.dart';
import 'package:plezy/mpv/player/player_streams.dart';
import 'package:plezy/screens/video_player/live_tv_session_state.dart';
import 'package:plezy/services/jellyfin_client.dart';

import '../test_helpers/backend_client_fixtures.dart';
import 'retained_hls_history_test.dart' show eventPlaylist;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final connection in [testJellyfinConnection(), testEmbyConnection()]) {
    group('${connection.dialect.productName} validated EVENT session', () {
      var count = 20;
      var originIdentity = 'origin-1';
      var missingSegments = false;
      var unavailable = false;
      var unsupported = false;
      var discontinuity = false;
      var mediaDelay = Duration.zero;
      var transientMediaFailures = 0;
      Completer<void>? manifestGate;
      final requests = <http.Request>[];
      late JellyfinClient client;
      late LiveTvPlaybackSession playback;
      late LiveTvHlsTimeshiftSession session;

      setUp(() async {
        count = 20;
        originIdentity = 'origin-1';
        missingSegments = unavailable = unsupported = false;
        discontinuity = false;
        mediaDelay = Duration.zero;
        transientMediaFailures = 0;
        manifestGate = null;
        requests.clear();
        client = JellyfinClient.forTesting(
          connection: connection,
          httpClient: MockClient((request) async {
            requests.add(request);
            final path = request.url.path;
            if (path.endsWith('/PlaybackInfo')) {
              return http.Response(
                jsonEncode({
                  'PlaySessionId': 'play-1',
                  'MediaSources': [
                    {
                      'Id': 'source-1',
                      'LiveStreamId': 'live-1',
                      'TranscodingUrl':
                          '/Videos/channel/master.m3u8?PlaySessionId=play-1&MediaSourceId=source-1&LiveStreamId=live-1',
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (path.endsWith('.ts')) {
              return http.Response(
                'x',
                missingSegments ? 404 : 206,
                headers: {
                  'etag': path.endsWith('segment-0.ts') ? originIdentity : 'segment',
                  'content-range': 'bytes 0-0/1000',
                },
              );
            }
            if (path.endsWith('master.m3u8')) {
              await manifestGate?.future;
              return http.Response(
                '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlive.m3u8?PlaySessionId=play-1\n',
                unavailable ? 503 : 200,
                headers: {'content-type': 'application/vnd.apple.mpegurl'},
              );
            }
            if (path.endsWith('live.m3u8')) {
              if (mediaDelay != Duration.zero) await Future<void>.delayed(mediaDelay);
              if (transientMediaFailures > 0) {
                transientMediaFailures--;
                return http.Response('', 503);
              }
              var text = eventPlaylist(count: count, extra: discontinuity ? '#EXT-X-DISCONTINUITY' : '');
              if (unsupported) text = text.replaceFirst('#EXT-X-PLAYLIST-TYPE:EVENT', '');
              return http.Response(text, 200, headers: {'content-type': 'application/vnd.apple.mpegurl'});
            }
            return http.Response('', 204);
          }),
        );
        playback = (await client.liveTv.startPlayback('channel'))!;
        session = playback as LiveTvHlsTimeshiftSession;
      });

      tearDown(() => client.close());

      test('a short initial playlist grows into a visible timeline with a decoded playhead', () async {
        count = 3;
        final start = (await session.preparePlayback())!;
        expect(
          playback.captureBuffer!.seekEndSeconds,
          3,
          reason: 'completed media is seekable before live hold-back fills',
        );
        expect(start.mediaStart, Duration.zero);
        final state = LiveTvSessionState(null)..adoptSession(playback);
        final opening = state.beginClockOpen(
          start.effectiveTargetEpoch!,
          mediaStart: start.mediaStart,
          mediaEpochOrigin: start.mediaEpochOrigin,
          mediaFirstSegmentEnd: start.mediaFirstSegmentEnd,
        );
        final ready = state.clockOpenResult(opening);
        state.bindClockOpen(opening, 1);
        state.calibrateClockSource(const PlayerSourceReady(sourceId: 1, position: Duration(milliseconds: 516)));
        expect(await ready, isTrue);
        count = 12;
        final update = (await playback.reportTimeline(state: 'paused', positionMs: 516, durationMs: 0))!;
        state.captureBuffer = update.captureBuffer;
        final window = session.seekWindow(state.captureBuffer!)!;
        final timeline = LiveTvTimeline.resolve(
          playback: state.playbackPosition(const Duration(milliseconds: 516)),
          seekable: window,
          metadataNowEpoch: DateTime.now().millisecondsSinceEpoch / 1000,
        );
        expect(timeline.estimatedPlayheadEpoch, start.mediaEpochOrigin! + .516);
        expect(timeline.visibleSeekStart, window.startEpoch);
        expect(timeline.visibleSeekEnd, window.endEpoch);
        final seek = await session.resolveSeek(targetEpoch: window.startEpoch + 3, buffer: state.captureBuffer!);
        expect(seek!.mediaStart, const Duration(seconds: 3));
      });

      test('cold media playlist exceeding the polling timeout still prepares a seekable source', () async {
        // The real Windows failure: PlaybackInfo and master succeed, but the
        // transcoder's media playlist is not ready inside five seconds.
        mediaDelay = const Duration(seconds: 6);
        final start = await session.preparePlayback();
        expect(start, isNotNull);
        expect(Uri.parse(start!.url).path, '/Videos/channel/live.m3u8');
        expect(start.mediaStart, const Duration(seconds: 14));
        expect(playback.captureBuffer, isNotNull);
        expect(requests.where((r) => r.url.path.endsWith('live.m3u8')), hasLength(2));
        expect(requests.where((r) => r.url.path.endsWith('/PlaybackInfo')), hasLength(1));
        mediaDelay = Duration.zero;
        final update = await playback.reportTimeline(state: 'paused', positionMs: 14000, durationMs: 0);
        expect(update!.captureBuffer, isNotNull);
        final seek = await session.resolveSeek(
          targetEpoch: start.mediaEpochOrigin! + 3,
          buffer: playback.captureBuffer!,
        );
        expect(seek!.mediaStart, const Duration(seconds: 3));
        expect(requests.any((r) => r.url.path.endsWith('/Stopped') || r.url.path.endsWith('/Close')), isFalse);
      });

      test('transient startup response retries without renegotiating or enabling unsupported history', () async {
        transientMediaFailures = 1;
        expect(await session.preparePlayback(), isNotNull);
        expect(requests.where((r) => r.url.path.endsWith('live.m3u8')), hasLength(2));
        expect(requests.where((r) => r.url.path.endsWith('/PlaybackInfo')), hasLength(1));
      });

      test('unsupported initial playlist is not retried as a cold transcoder', () async {
        unsupported = true;
        expect(await session.preparePlayback(), isNull);
        expect(playback.captureBuffer, isNull);
        expect(requests.where((r) => r.url.path.endsWith('live.m3u8')), hasLength(1));
      });

      test('copy permissions, fixed variant, headers, and seek coordinates', () async {
        final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
        expect(body['EnableDirectPlay'], isFalse);
        expect(body['EnableDirectStream'], isFalse);
        expect(body['AllowAudioStreamCopy'], isTrue);
        expect(body['AllowVideoStreamCopy'], isTrue);
        expect(playback.captureBuffer, isNull, reason: 'must first prepare the native origin');
        final start = (await session.preparePlayback())!;
        expect(start.mediaStart, const Duration(seconds: 14));
        expect(Uri.parse(start.url).path, '/Videos/channel/live.m3u8');
        final buffer = playback.captureBuffer!;
        final backward = (await session.resolveSeek(targetEpoch: buffer.startedAt + 3, buffer: buffer))!;
        expect(backward.mediaStart, const Duration(seconds: 3));
        expect(backward.mediaEpochOrigin, start.mediaEpochOrigin);
        expect(backward.url, start.url);
        expect(requests.where((r) => r.url.path.endsWith('/PlaybackInfo')), hasLength(1));
        for (final request in requests.where((r) => r.method == 'GET')) {
          expect(request.headers['user-agent'], session.playbackHeaders['User-Agent']);
          expect(request.url.queryParameters[connection.dialect.tokenQueryParam], connection.accessToken);
        }
        expect(requests.any((r) => r.headers['range'] == 'bytes=0-0'), isTrue);
      });

      test('paused heartbeats and reload intents preserve IDs and growing history', () async {
        final start = (await session.preparePlayback())!;
        final origin = start.mediaEpochOrigin;
        await playback.reportTimeline(state: 'playing', positionMs: 14000, durationMs: 0);
        count = 100;
        final update = await playback.reportTimeline(state: 'paused', positionMs: 3000, durationMs: 0);
        expect(update!.captureBuffer!.seekEndSeconds, 100);
        expect(update.captureBuffer!.startedAt, origin);
        for (final seconds in [3, 80, 5, 90]) {
          final seek = await session.resolveSeek(targetEpoch: origin! + seconds, buffer: playback.captureBuffer!);
          expect(seek!.mediaStart, Duration(seconds: seconds));
        }
        final live = await session.resolveSeek(targetEpoch: null, buffer: playback.captureBuffer!);
        expect(live!.mediaStart, const Duration(seconds: 94));
        final reports = requests.where((r) => r.url.path.contains('/Sessions/Playing')).toList();
        expect(reports, hasLength(2));
        for (final report in reports) {
          final body = jsonDecode(report.body) as Map<String, dynamic>;
          expect(body['PlaySessionId'], 'play-1');
          expect(body['MediaSourceId'], 'source-1');
          expect(body['LiveStreamId'], 'live-1');
        }
        expect(jsonDecode(reports.last.body)['IsPaused'], isTrue);
        expect(jsonDecode(reports.last.body)['PositionTicks'], 30000000);
        expect(requests.any((r) => r.url.path.endsWith('/Stopped') || r.url.path.endsWith('/Close')), isFalse);
      });

      test('manual seeks reach the last completed segment while Go Live keeps its preferred latency', () async {
        final start = (await session.preparePlayback())!;
        final buffer = playback.captureBuffer!;
        final window = session.seekWindow(buffer)!;
        expect(start.mediaStart, const Duration(seconds: 14));
        expect(session.preferredLiveEpoch, buffer.startedAt + 14);
        expect(window.endEpoch, buffer.startedAt + 19);
        for (final requested in [18, 19, 20, 1000]) {
          final seek = (await session.resolveSeek(targetEpoch: buffer.startedAt + requested, buffer: buffer))!;
          expect(seek.mediaStart, Duration(seconds: requested == 18 ? 18 : 19));
          expect(seek.url, start.url);
        }
        expect(requests.any((r) => r.url.path.endsWith('segment-19.ts') && r.headers['range'] == 'bytes=0-0'), isTrue);
        final live = (await session.resolveSeek(targetEpoch: null, buffer: buffer))!;
        expect(live.mediaStart, const Duration(seconds: 14));
        expect(requests.where((r) => r.url.path.endsWith('/PlaybackInfo')), hasLength(1));
        unavailable = true;
        await playback.reportTimeline(state: 'paused', positionMs: 19000, durationMs: 0);
        expect(session.preferredLiveEpoch, isNull);
        expect(await session.resolveSeek(targetEpoch: buffer.startedAt + 19, buffer: buffer), isNull);
      });

      test('same-named server job replacement invalidates its origin', () async {
        await session.preparePlayback();
        final buffer = playback.captureBuffer!;
        originIdentity = 'replacement';
        expect(await session.resolveSeek(targetEpoch: buffer.startedAt + 2, buffer: buffer), isNull);
        expect(playback.captureBuffer, isNull);
        originIdentity = 'origin-1';
        expect(await session.preparePlayback(), isNull);
      });

      test('observed discontinuity retires history even if a later manifest hides the tag', () async {
        await session.preparePlayback();
        discontinuity = true;
        final update = await playback.reportTimeline(state: 'paused', positionMs: 3000, durationMs: 0);
        expect(update!.clearCaptureBuffer, isTrue);
        expect(update.clearPlaybackClock, isTrue);
        discontinuity = false;
        expect(await session.preparePlayback(), isNull);
        expect(playback.captureBuffer, isNull);
      });

      test('removed files never open; unsupported and stale manifests never invent bounds', () async {
        unsupported = true;
        expect(await session.preparePlayback(), isNull);
        expect(playback.captureBuffer, isNull);
        unsupported = false;
        await session.preparePlayback();
        final buffer = playback.captureBuffer!;
        unavailable = true;
        expect(await session.preparePlayback(), isNull);
        expect(playback.captureBuffer, isNull);
        unavailable = false;
        missingSegments = true;
        expect(await session.resolveSeek(targetEpoch: buffer.startedAt + 2, buffer: buffer), isNull);
        expect(playback.captureBuffer, isNull);
      });

      test('stop is terminal and new channel gets an independent origin', () async {
        await session.preparePlayback();
        final buffer = playback.captureBuffer!;
        await playback.reportTimeline(state: 'stopped', positionMs: 3000, durationMs: 0);
        expect(await session.resolveSeek(targetEpoch: buffer.startedAt, buffer: buffer), isNull);
        expect(playback.captureBuffer, isNull);
        await pumpEventQueue();
        expect(requests.where((r) => r.url.path.endsWith('/Stopped')), hasLength(1));
        final next = (await client.liveTv.startPlayback('another-channel'))!;
        expect(next.captureBuffer, isNull);
        expect(await (next as LiveTvHlsTimeshiftSession).preparePlayback(), isNotNull);
      });

      test('stop during playlist fetch cannot publish history from the abandoned channel', () async {
        manifestGate = Completer<void>();
        final preparing = session.preparePlayback();
        await pumpEventQueue();
        await playback.reportTimeline(state: 'stopped', positionMs: 0, durationMs: 0);
        manifestGate!.complete();
        expect(await preparing, isNull);
        expect(playback.captureBuffer, isNull);
      });
    });
  }
}
