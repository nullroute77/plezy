import '../i18n/strings.g.dart';
import '../utils/json_utils.dart';
import '../media/ids.dart';

enum GuideProgramBadge { live, newProgram }

/// Represents an EPG program entry (what's on a channel at a given time)
class LiveTvProgram {
  final String? key;
  final String? ratingKey;
  final String? guid;
  final String title;

  /// Backend-normalized broadcast name and episode/secondary title. Keep
  /// [title] and the Plex hierarchy intact for details and recording actions.
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
  final bool? isNew;
  final bool? repeat;

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
    this.isNew,
    this.repeat,
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

    // Broadcast flags belong to the selected airing when Media supplies them.
    bool? pickBool(String key) => flexibleBoolNullable(media?[key]) ?? flexibleBoolNullable(json[key]);

    final seriesTitle = (json['grandparentTitle'] as String?)?.trim();
    final hasSeriesTitle = seriesTitle != null && seriesTitle.isNotEmpty;
    return LiveTvProgram(
      programTitle: hasSeriesTitle ? seriesTitle : json['title'] as String?,
      episodeTitle: hasSeriesTitle ? json['title'] as String? : null,
      key: json['key'] as String?,
      ratingKey: json['ratingKey'] as String?,
      guid: json['guid'] as String?,
      title: json['title'] as String? ?? t.liveTv.unknownProgram,
      summary: json['summary'] as String?,
      contentRating: pickString('contentRating'),
      type: json['type'] as String?,
      year: flexibleInt(json['year']),
      beginsAt: pickInt('beginsAt'),
      endsAt: pickInt('endsAt'),
      grandparentTitle: json['grandparentTitle'] as String?,
      parentTitle: json['parentTitle'] as String?,
      index: flexibleInt(json['index']),
      parentIndex: flexibleInt(json['parentIndex']),
      thumb: json['thumb'] as String? ?? json['grandparentThumb'] as String?,
      art: json['art'] as String?,
      channelIdentifier: pickString('channelIdentifier') ?? channel?['id']?.toString(),
      channelCallSign: pickString('channelCallSign'),
      live: pickBool('live'),
      premiere: pickBool('premiere'),
      isNew: pickBool('new'),
      repeat: pickBool('repeat'),
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
      isNew: isNew,
      repeat: repeat,
      subscriptionId: subscriptionId,
      grandparentSubscriptionId: grandparentSubscriptionId,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      liveDvrKey: liveDvrKey ?? this.liveDvrKey,
      providerIdentifier: providerIdentifier ?? this.providerIdentifier,
    );
  }

  /// A currently airing repeat is not a live broadcast. Unknown flags never
  /// imply NEW, and an explicit repeat vetoes conflicting new/premiere flags.
  GuideProgramBadge? get guideBadge {
    if (live == true) return GuideProgramBadge.live;
    if (repeat != true && (isNew == true || premiere == true)) return GuideProgramBadge.newProgram;
    return null;
  }

  String get guideTitle => programTitle ?? grandparentTitle ?? title;

  static final _episodePlaceholder = RegExp(r'^episode\s+[0-9]+$', caseSensitive: false);

  /// Match the guide's episode-title-only presentation, without synthesizing
  /// season/episode numbers. Only an entire `Episode <digits>` is a placeholder;
  /// titles such as "Episode 2000: A New Beginning" remain useful.
  String? get guideSubtitle {
    final secondary = (episodeTitle ?? (programTitle == null && grandparentTitle != null ? title : null))?.trim();
    if (secondary == null || secondary.isEmpty || _episodePlaceholder.hasMatch(secondary)) return null;
    return secondary;
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
}
