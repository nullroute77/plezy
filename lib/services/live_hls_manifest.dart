import 'retained_hls_history.dart';

/// Resolve a fixed, same-server media playlist. Separate audio renditions and
/// variant switching would need coordinated histories, so do not guess one.
Future<RetainedHlsPlaylist?> fetchLiveHlsManifest(Uri negotiated, Future<String?> Function(Uri uri) fetch) async {
  var uri = negotiated;
  for (var depth = 0; depth < 3; depth++) {
    final text = await fetch(uri);
    if (text == null) return null;
    if (!text.contains('#EXT-X-STREAM-INF:')) return RetainedHlsPlaylist.parse(uri, text);
    final lines = text.split(RegExp(r'\r?\n')).map((line) => line.trim()).toList();
    if (lines.any((line) => line.startsWith('#EXT-X-MEDIA:') && line.contains('URI='))) return null;
    final variants = <Uri>[];
    var pending = false;
    for (final line in lines) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pending = true;
      } else if (pending && line.isNotEmpty && !line.startsWith('#')) {
        final next = uri.resolve(line);
        if (next.origin != negotiated.origin) return null;
        variants.add(next);
        pending = false;
      }
    }
    // Both negotiated server profiles normally expose one muxed variant.
    // Refuse ambiguity rather than inspect one and let MPV choose another.
    if (variants.length != 1 || pending) return null;
    uri = variants.single;
  }
  return null;
}
