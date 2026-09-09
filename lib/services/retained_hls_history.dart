import '../models/livetv_capture_buffer.dart';

/// Completed segments in an append-only HLS EVENT playlist. The media origin
/// must remain present: the pinned FFmpeg rebases timestamps at its first
/// decoded segment, so sliding windows need a different player contract.
class RetainedHlsPlaylist {
  final Uri uri;
  final int sequence;
  final double targetDuration;
  final List<({Uri uri, double duration})> segments;
  final String? initialization;
  final double? epochOrigin;

  RetainedHlsPlaylist._({
    required this.uri,
    required this.sequence,
    required this.targetDuration,
    required this.segments,
    required this.initialization,
    required this.epochOrigin,
  });

  double get duration => segments.fold(0, (sum, segment) => sum + segment.duration);

  static RetainedHlsPlaylist? parse(Uri uri, String text) {
    final lines = text.trim().split(RegExp(r'\r?\n')).map((line) => line.trim()).toList();
    if (lines.isEmpty || lines.first != '#EXTM3U' || !lines.contains('#EXT-X-PLAYLIST-TYPE:EVENT')) return null;
    var sequence = 0;
    double? targetDuration;
    double? pendingDuration;
    double? origin;
    var consistentClock = true;
    double elapsed = 0;
    String? initialization;
    final segments = <({Uri uri, double duration})>[];
    for (final line in lines.skip(1)) {
      // Gaps, encryption, byte ranges and timestamp resets require player
      // contracts this adapter does not yet implement. Never bridge them.
      if (line.startsWith('#EXT-X-DISCONTINUITY') ||
          line.startsWith('#EXT-X-GAP') ||
          line.startsWith('#EXT-X-KEY') ||
          line.startsWith('#EXT-X-BYTERANGE') ||
          line.startsWith('#EXT-X-STREAM-INF') ||
          line.startsWith('#EXT-X-SKIP')) {
        return null;
      }
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        final parsed = int.tryParse(line.substring(22));
        if (parsed == null || parsed < 0) return null;
        sequence = parsed;
      } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        targetDuration = double.tryParse(line.substring(22));
      } else if (line.startsWith('#EXTINF:')) {
        if (pendingDuration != null) return null;
        pendingDuration = double.tryParse(line.substring(8).split(',').first);
        if (pendingDuration == null || !pendingDuration.isFinite || pendingDuration <= 0) return null;
      } else if (line.startsWith('#EXT-X-MAP:')) {
        if (segments.isNotEmpty || initialization != null || line.contains('BYTERANGE=')) return null;
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match == null) return null;
        final mapUri = uri.resolve(match.group(1)!);
        if (mapUri.origin != uri.origin) return null;
        initialization = mapUri.toString();
      } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
        final value = line.substring(25);
        final date = DateTime.tryParse(value);
        if (date == null || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
          consistentClock = false;
        } else {
          final candidate = date.millisecondsSinceEpoch / 1000.0 - elapsed;
          if (origin != null && (candidate - origin).abs() > 0.1) consistentClock = false;
          origin = candidate;
        }
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        if (pendingDuration == null) return null;
        final segmentUri = uri.resolve(line);
        if (segmentUri.scheme != 'http' && segmentUri.scheme != 'https') return null;
        if (segmentUri.origin != uri.origin) return null;
        segments.add((uri: segmentUri, duration: pendingDuration));
        elapsed += pendingDuration;
        pendingDuration = null;
      }
    }
    if (pendingDuration != null ||
        segments.isEmpty ||
        targetDuration == null ||
        !targetDuration.isFinite ||
        targetDuration <= 0 ||
        !elapsed.isFinite) {
      return null;
    }
    return RetainedHlsPlaylist._(
      uri: uri,
      sequence: sequence,
      targetDuration: targetDuration,
      segments: List.unmodifiable(segments),
      initialization: initialization,
      epochOrigin: consistentClock ? origin : null,
    );
  }

  bool extendsPlaylist(RetainedHlsPlaylist previous) {
    if (uri != previous.uri ||
        sequence != previous.sequence ||
        initialization != previous.initialization ||
        segments.length < previous.segments.length) {
      return false;
    }
    for (var i = 0; i < previous.segments.length; i++) {
      if (segments[i] != previous.segments[i]) return false;
    }
    return true;
  }
}

/// Session-scoped history, with freshness independent of its broadcast clock.
/// A changed prefix permanently retires this origin; a new tune must create a
/// new instance. Wall time never extends the seekable range.
class RetainedHlsHistory {
  RetainedHlsPlaylist? _playlist;
  double? _origin;
  DateTime? _refreshedAt;
  bool _invalid = false;
  bool exactClock = false;

  RetainedHlsPlaylist? get playlist => _invalid ? null : _playlist;
  double? get epochOrigin => _invalid ? null : _origin;
  bool get isRetired => _invalid;

  bool isFresh(DateTime now) =>
      !_invalid && _refreshedAt != null && now.difference(_refreshedAt!) <= const Duration(seconds: 15);

  void invalidate() {
    _invalid = true;
    _refreshedAt = null;
  }

  void unavailable() => _refreshedAt = null;

  bool update(RetainedHlsPlaylist next, DateTime now) {
    if (_invalid) return false;
    final previous = _playlist;
    if (previous != null && !next.extendsPlaylist(previous)) {
      invalidate();
      return false;
    }
    if (_origin == null) {
      _origin = next.epochOrigin ?? now.millisecondsSinceEpoch / 1000.0 - next.duration;
      exactClock = next.epochOrigin != null;
    } else if (next.epochOrigin == null || (next.epochOrigin! - _origin!).abs() > 0.1) {
      // Conflicting broadcast tags lower clock confidence, not seekability.
      // Keep the already established continuous player mapping as an estimate.
      exactClock = false;
    }
    _playlist = next;
    _refreshedAt = now;
    return true;
  }

  CaptureBuffer? buffer(DateTime now) {
    final snapshot = playlist;
    final refreshedAt = _refreshedAt;
    if (snapshot == null || refreshedAt == null || now.difference(refreshedAt) > const Duration(seconds: 15)) {
      return null;
    }
    // Three target durations behind the completed edge follows HLS's live
    // safety guidance. The UI's newest target is available media, not RF live.
    final end = snapshot.duration - 3 * snapshot.targetDuration;
    if (end <= 0) return null;
    return CaptureBuffer(startedAt: _origin!, seekStartSeconds: 0, seekEndSeconds: end);
  }
}
