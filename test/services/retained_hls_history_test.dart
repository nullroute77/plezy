import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/live_hls_manifest.dart';
import 'package:plezy/services/retained_hls_history.dart';

String eventPlaylist({int count = 20, int sequence = 17, String extra = '', double duration = 1}) =>
    '''
#EXTM3U
#EXT-X-PLAYLIST-TYPE:EVENT
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:$sequence
$extra
${List.generate(count, (i) => '#EXTINF:$duration,\nsegment-$i.ts').join('\n')}
''';

void main() {
  final uri = Uri.parse('https://server.example/video/live.m3u8');
  final now = DateTime.utc(2026, 9, 9, 12);
  RetainedHlsPlaylist parse(String text) => RetainedHlsPlaylist.parse(uri, text)!;

  test('actual durations define bounds; media sequence is never seconds', () {
    final history = RetainedHlsHistory();
    expect(history.update(parse(eventPlaylist(duration: 1.5)), now), isTrue);
    final buffer = history.buffer(now)!;
    expect(buffer.seekStartSeconds, 0);
    expect(buffer.seekEndSeconds, 24);
    expect(buffer.startedAt, now.millisecondsSinceEpoch / 1000 - 30);
    expect(history.exactClock, isFalse);
    expect(history.buffer(now.add(const Duration(seconds: 16))), isNull);
  });

  test('pause updates grow history without moving its estimated origin', () {
    final history = RetainedHlsHistory();
    history.update(parse(eventPlaylist()), now);
    final origin = history.epochOrigin;
    history.update(parse(eventPlaylist(count: 40)), now.add(const Duration(minutes: 20)));
    expect(history.epochOrigin, origin);
    expect(history.buffer(now.add(const Duration(minutes: 20)))!.seekEndSeconds, 34);
    history.unavailable();
    expect(history.buffer(now), isNull);
    expect(history.isFresh(now), isFalse);
  });

  test('consistent PDT supplies clock independently of history validity', () {
    final history = RetainedHlsHistory();
    history.update(parse(eventPlaylist(extra: '#EXT-X-PROGRAM-DATE-TIME:2026-09-09T11:00:00Z')), now);
    expect(history.exactClock, isTrue);
    expect(history.epochOrigin, DateTime.utc(2026, 9, 9, 11).millisecondsSinceEpoch / 1000);
    final inconsistent = eventPlaylist()
        .replaceFirst('segment-0.ts', 'segment-0.ts\n#EXT-X-PROGRAM-DATE-TIME:2026-09-09T11:00:00Z')
        .replaceFirst('segment-1.ts', 'segment-1.ts\n#EXT-X-PROGRAM-DATE-TIME:2026-09-09T12:00:00Z');
    expect(RetainedHlsPlaylist.parse(uri, inconsistent), isNull);
  });

  for (final mutation in <String Function(String)>[
    (text) => eventPlaylist(count: 10),
    (text) => eventPlaylist(sequence: 18),
    (text) => text.replaceFirst('segment-0.ts', 'replacement.ts'),
    (text) => text.replaceFirst('#EXTINF:1.0', '#EXTINF:1.1'),
  ]) {
    test('changed history cannot regain a retired origin', () {
      final history = RetainedHlsHistory();
      history.update(parse(eventPlaylist()), now);
      expect(history.update(parse(mutation(eventPlaylist())), now), isFalse);
      expect(history.buffer(now), isNull);
      expect(history.update(parse(eventPlaylist(count: 40)), now), isFalse);
    });
  }

  for (final tag in [
    '#EXT-X-DISCONTINUITY',
    '#EXT-X-GAP',
    '#EXT-X-KEY:METHOD=AES-128,URI="key"',
    '#EXT-X-BYTERANGE:100@0',
    '#EXT-X-SKIP:SKIPPED-SEGMENTS=3',
  ]) {
    test('unsupported tag $tag cannot expose a false continuous window', () {
      expect(RetainedHlsPlaylist.parse(uri, eventPlaylist(extra: tag)), isNull);
    });
  }

  test('untyped, sliding, malformed and incomplete playlists are unsupported', () {
    for (final text in [
      eventPlaylist().replaceFirst('#EXT-X-PLAYLIST-TYPE:EVENT', ''),
      eventPlaylist().replaceFirst('#EXT-X-PLAYLIST-TYPE:EVENT', '#EXT-X-PLAYLIST-TYPE:VOD'),
      eventPlaylist().replaceFirst('#EXTINF:1.0', '#EXTINF:NaN'),
      '${eventPlaylist()}#EXTINF:1,\n',
      eventPlaylist().replaceFirst('segment-0.ts', 'https://unrelated.example/segment.ts'),
    ]) {
      expect(RetainedHlsPlaylist.parse(uri, text), isNull);
    }
  });

  test('fMP4 initialization identity belongs to the history', () {
    final history = RetainedHlsHistory();
    history.update(parse(eventPlaylist(extra: '#EXT-X-MAP:URI="init.mp4"')), now);
    expect(history.playlist!.initialization, 'https://server.example/video/init.mp4');
    expect(history.update(parse(eventPlaylist(extra: '#EXT-X-MAP:URI="new.mp4"')), now), isFalse);
  });

  test('master resolves exactly the media playlist the player will open', () async {
    final fetched = <Uri>[];
    final result = await fetchLiveHlsManifest(uri, (request) async {
      fetched.add(request);
      return request == uri ? '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmedia.m3u8\n' : eventPlaylist();
    });
    expect(result!.uri, uri.resolve('media.m3u8'));
    expect(fetched.length, 2);
    for (final master in [
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nhttps://other.example/media.m3u8',
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000\nb.m3u8',
      '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmedia.m3u8',
    ]) {
      expect(await fetchLiveHlsManifest(uri, (_) async => master), isNull);
    }
  });
}
