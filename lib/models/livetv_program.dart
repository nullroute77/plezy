import '../i18n/strings.g.dart';
import '../utils/json_utils.dart';
import '../media/ids.dart';

/// Represents an EPG program entry (what's on a channel at a given time)
class LiveTvProgram {
  final String? key;
  final String? ratingKey;
  final String? guid;
  final String title;

  /// Broadcast title and episode subtitle as supplied by the guide provider.
  final String? programTitle;
  final String? episodeTitle;
  final String? summary;
  final String? contentRating;
  final String? type;
  final int? year;
  final int? beginsAt; // epoch seconds
  final int? endsAt; // epoch seconds
  final String? grandparentTitle; // series name for episodes
  final String? parentTitle; // season name
  final int? index; // episode number
  final int? parentIndex; // season number
  final String? thumb;
  final String? art;
  final String? channelIdentifier;
  final String? channelCallSign;
  final bool? live;
  final bool? premiere;

  /// Recording-rule key targeting this airing directly (`subscriptionID`).
  /// Plex stamps subscribed airings in the grid/metadata responses themselves;
  /// the official client derives its "scheduled" state from these attributes.
  final String? subscriptionId;

  /// Recording-rule key targeting this airing's show (`grandparentSubscriptionID`).
  final String? grandparentSubscriptionId;
  final String? serverId;
  final String? serverName;
  final String? liveDvrKey;
  final String? providerIdentifier;

  LiveTvProgram({
    this.key,
    this.ratingKey,
    this.guid,
    required this.title,
    this.programTitle,
    this.episodeTitle,
    this.summary,
    this.contentRating,
    this.type,
    this.year,
    this.beginsAt,
    this.endsAt,
    this.grandparentTitle,
    this.parentTitle,
    this.index,
    this.parentIndex,
    this.thumb,
    this.art,
    this.channelIdentifier,
    this.channelCallSign,
    this.live,
    this.premiere,
    this.subscriptionId,
    this.grandparentSubscriptionId,
    this.serverId,
    this.serverName,
    this.liveDvrKey,
    this.providerIdentifier,
  });

  factory LiveTvProgram.fromJson(Map<String, dynamic> json, {Map<String, dynamic>? mediaOverride}) {
    // Grid endpoint nests timing/channel info inside Media[] and Channel[].
    // When mediaOverride is supplied, the caller is pinning this parse to a
    // specific airing (one Media entry); treat it as authoritative for
    // begin/end/channel fields.
    final hasOverride = mediaOverride != null;
    final media = mediaOverride ?? (json['Media'] as List?)?.firstOrNull as Map<String, dynamic>?;
    final channel = (json['Channel'] as List?)?.firstOrNull as Map<String, dynamic>?;

    int? pickInt(String key) {
      final fromMedia = flexibleInt(media?[key]);
      final fromJson = flexibleInt(json[key]);
      return hasOverride ? (fromMedia ?? fromJson) : (fromJson ?? fromMedia);
    }

    String? pickString(String key) {
      final fromMedia = media?[key]?.toString();
      final fromJson = json[key] as String?;
      return hasOverride ? (fromMedia ?? fromJson) : (fromJson ?? fromMedia);
    }

    bool? pickBool(String key) {
      final fromMedia = flexibleBoolNullable(media?[key]);
      final fromJson = flexibleBoolNullable(json[key]);
      return hasOverride ? (fromMedia ?? fromJson) : (fromJson ?? fromMedia);
    }

    final title = json['title'] as String?;
    final series = json['grandparentTitle'] as String?;
    final seriesTitle = _guideText(series);
    return LiveTvProgram(
      key: json['key'] as String?,
      ratingKey: json['ratingKey'] as String?,
      guid: json['guid'] as String?,
      title: title ?? t.liveTv.unknownProgram,
      programTitle: seriesTitle ?? title ?? t.liveTv.unknownProgram,
      episodeTitle: seriesTitle == null ? null : title,
      summary: json['summary'] as String?,
      contentRating: pickString('contentRating'),
      type: json['type'] as String?,
      year: flexibleInt(json['year']),
      beginsAt: pickInt('beginsAt'),
      endsAt: pickInt('endsAt'),
      grandparentTitle: series,
      parentTitle: json['parentTitle'] as String?,
      index: flexibleInt(json['index']),
      parentIndex: flexibleInt(json['parentIndex']),
      thumb: json['thumb'] as String? ?? json['grandparentThumb'] as String?,
      art: json['art'] as String?,
      channelIdentifier: pickString('channelIdentifier') ?? channel?['id']?.toString(),
      channelCallSign: pickString('channelCallSign'),
      live: flexibleBool(json['live']),
      // Plex flags premieres per airing, on the Media entry.
      premiere: pickBool('premiere'),
      subscriptionId: json['subscriptionID']?.toString(),
      grandparentSubscriptionId: json['grandparentSubscriptionID']?.toString(),
    );
  }

  LiveTvProgram copyWith({ServerId? serverId, String? serverName, String? liveDvrKey, String? providerIdentifier}) {
    return LiveTvProgram(
      key: key,
      ratingKey: ratingKey,
      guid: guid,
      title: title,
      programTitle: programTitle,
      episodeTitle: episodeTitle,
      summary: summary,
      contentRating: contentRating,
      type: type,
      year: year,
      beginsAt: beginsAt,
      endsAt: endsAt,
      grandparentTitle: grandparentTitle,
      parentTitle: parentTitle,
      index: index,
      parentIndex: parentIndex,
      thumb: thumb,
      art: art,
      channelIdentifier: channelIdentifier,
      channelCallSign: channelCallSign,
      live: live,
      premiere: premiere,
      subscriptionId: subscriptionId,
      grandparentSubscriptionId: grandparentSubscriptionId,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      liveDvrKey: liveDvrKey ?? this.liveDvrKey,
      providerIdentifier: providerIdentifier ?? this.providerIdentifier,
    );
  }

  /// Key of the recording rule covering this airing, or null when the server
  /// did not tag it as subscribed. The show-level rule wins over an item-level
  /// one, matching how the official client resolves these attributes.
  String? get recordingRuleKey {
    final show = grandparentSubscriptionId?.trim();
    if (show != null && show.isNotEmpty) return show;
    final item = subscriptionId?.trim();
    if (item != null && item.isNotEmpty) return item;
    return null;
  }

  DateTime? get startTime => beginsAt != null ? DateTime.fromMillisecondsSinceEpoch(beginsAt! * 1000) : null;

  DateTime? get endTime => endsAt != null ? DateTime.fromMillisecondsSinceEpoch(endsAt! * 1000) : null;

  int get durationMinutes {
    if (beginsAt == null || endsAt == null) return 0;
    return ((endsAt! - beginsAt!) / 60).round();
  }

  bool get isCurrentlyAiring {
    if (beginsAt == null || endsAt == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= beginsAt! && now < endsAt!;
  }

  double get progress {
    if (beginsAt == null || endsAt == null) return 0.0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now < beginsAt!) return 0.0;
    if (now >= endsAt!) return 1.0;
    return (now - beginsAt!) / (endsAt! - beginsAt!);
  }

  String get displayTitle {
    if (grandparentTitle != null && index != null) {
      final seasonEpisode = parentIndex != null ? 'S${parentIndex}E$index' : 'E$index';
      return '$grandparentTitle - $seasonEpisode - $title';
    }
    return title;
  }

  String get guideTitle =>
      _guideText(programTitle) ?? _guideText(grandparentTitle) ?? _guideText(title) ?? t.liveTv.unknownProgram;

  String? get guideSubtitle =>
      _guideText(episodeTitle ?? (programTitle == null && _guideText(grandparentTitle) != null ? title : null));

  static final _episodePlaceholder = RegExp(r'^episode\s+[0-9]+$', caseSensitive: false);

  static String? _guideText(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty || _episodePlaceholder.hasMatch(text)) return null;
    return text;
  }
}
