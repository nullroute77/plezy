part of '../../jellyfin_client.dart';

mixin _JellyfinLiveTvMethods on _JellyfinClientInternals {
  /// Returns `true` when this server has Live TV configured (channels
  /// available). Probes `/LiveTv/Channels?limit=1`. Used by [MultiServerProvider]
  /// to gate the Live TV menu.
  Future<bool> hasLiveTv() async {
    try {
      final response = await _http.get(
        '/LiveTv/Channels',
        queryParameters: {'limit': '1', 'userId': connection.userId},
      );
      if (response.statusCode != 200) return false;
      final data = response.data;
      if (data is Map<String, dynamic>) {
        final total = data['TotalRecordCount'];
        if (total is int) return total > 0;
        final items = data['Items'];
        if (items is List) return items.isNotEmpty;
      }
      return false;
    } catch (e) {
      appLogger.d('${dialect.productName} Live TV probe failed', error: e);
      return false;
    }
  }

  /// Fetch the user's Live TV channel list. Each `BaseItemDto` of type
  /// `TvChannel` is mapped to a [LiveTvChannel].
  Future<List<LiveTvChannel>> fetchLiveTvChannels() async {
    final items = await _safeFetchItemsArray('/LiveTv/Channels', {
      'userId': connection.userId,
      'enableImages': 'true',
      'enableUserData': 'true',
      'sortBy': 'SortName',
      'sortOrder': 'Ascending',
    });
    return items.map(_channelFromJson).toList();
  }

  /// EPG / programs grid. [channelIds] scopes to specific channels (when
  /// empty, the server returns programs across all channels). [beginsAt] /
  /// [endsAt] are epoch seconds and bound the time window — both MediaBrowser
  /// dialects use ISO 8601 strings on the wire. The lower bound is sent as
  /// `minEndDate` (programme still running at window start), not
  /// `minStartDate` (started inside the window), so a currently-airing
  /// programme that began before the window still overlaps it.
  Future<List<LiveTvProgram>> fetchLiveTvPrograms({
    List<String> channelIds = const [],
    int? beginsAt,
    int? endsAt,
  }) async {
    DateTime? toDt(int? epoch) => epoch == null ? null : DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
    final params = <String, dynamic>{
      'userId': connection.userId,
      'enableImages': 'true',
      'sortBy': 'StartDate',
      'sortOrder': 'Ascending',
      if (channelIds.isNotEmpty) 'channelIds': channelIds.join(','),
      if (beginsAt != null) 'minEndDate': toDt(beginsAt)!.toIso8601String(),
      if (endsAt != null) 'maxStartDate': toDt(endsAt)!.toIso8601String(),
    };
    final items = await _safeFetchItemsArray('/LiveTv/Programs', params);
    return items.map(_programFromJson).toList();
  }

  LiveTvProgram _programFromJson(Map<String, dynamic> json) {
    final id = json['Id'] as String?;

    final tags = json['ImageTags'];
    String? primaryTag;
    if (tags is Map<String, dynamic>) {
      primaryTag = tags['Primary'] as String?;
    }
    final thumbPath = (id != null && primaryTag != null)
        ? _absolutizeImagePath('/Items/${_segment(id)}/Images/Primary?tag=${Uri.encodeComponent(primaryTag)}')
        : null;
    // TimerId is only present while a recording is actually scheduled/running
    // (the server omits it for cancelled timers). SeriesTimerId alone means a
    // series rule exists but skips this airing, so the series key is only
    // stamped when the airing really records — recordingRuleKey drives both
    // the guide's red dot and the Manage action.
    final timerId = json['TimerId'] as String?;
    final seriesTimerId = json['SeriesTimerId'] as String?;
    final recording = timerId != null && timerId.isNotEmpty;
    return LiveTvProgram(
      key: id,
      ratingKey: id,
      // The program id doubles as the recording seed: getSubscriptionTemplate
      // feeds it to /LiveTv/Timers/Defaults?programId=.
      guid: id,
      title: json['Name'] as String? ?? t.liveTv.unknownProgram,
      summary: json['Overview'] as String?,
      type: 'episode',
      year: (json['ProductionYear'] as num?)?.toInt(),
      beginsAt: jellyfinIsoToEpochSeconds(json['StartDate'] as String?),
      endsAt: jellyfinIsoToEpochSeconds(json['EndDate'] as String?),
      grandparentTitle: json['SeriesName'] as String?,
      parentTitle: json['SeasonName'] as String?,
      index: (json['IndexNumber'] as num?)?.toInt(),
      parentIndex: (json['ParentIndexNumber'] as num?)?.toInt(),
      thumb: thumbPath,
      art: null,
      channelIdentifier: json['ChannelId'] as String?,
      channelCallSign: json['ChannelCallSign'] as String? ?? json['ChannelName'] as String?,
      live: json['IsLive'] as bool?,
      premiere: json['IsPremiere'] as bool?,
      subscriptionId: recording ? '$_jfTimerRuleKeyPrefix$timerId' : null,
      grandparentSubscriptionId: recording && seriesTimerId != null && seriesTimerId.isNotEmpty
          ? '$_jfSeriesRuleKeyPrefix$seriesTimerId'
          : null,
      serverId: serverId,
      serverName: serverName,
    );
  }

  LiveTvChannel _channelFromJson(Map<String, dynamic> json) {
    final id = json['Id'] as String? ?? '';
    final name = json['Name'] as String?;
    final number = json['Number'] as String? ?? json['ChannelNumber'] as String?;
    final tags = json['ImageTags'];
    String? primaryTag;
    if (tags is Map<String, dynamic>) {
      primaryTag = tags['Primary'] as String?;
    }
    final thumbPath = primaryTag != null
        ? _absolutizeImagePath('/Items/${_segment(id)}/Images/Primary?tag=${Uri.encodeComponent(primaryTag)}')
        : null;
    return LiveTvChannel(
      key: id,
      identifier: id,
      callSign: json['CallSign'] as String?,
      title: name,
      thumb: thumbPath,
      art: null,
      number: number,
      hd: false,
      lineup: null,
      slug: null,
      drm: null,
      serverId: serverId,
      serverName: serverName,
    );
  }

  /// Release a live stream that the PlaybackInfo negotiation opened
  /// (`AutoOpenLiveStream`) but no playback session will ever stop-report.
  /// Without it the server's consumer count never drops and the tuner slot
  /// leaks until an idle timeout (#2198). The server wants `liveStreamId` in
  /// the query string (400 when in the body) and answers 204. Best-effort:
  /// a failure only defers to the server's own reclaim.
  Future<void> _closeLiveStream(String liveStreamId) async {
    try {
      final response = await _http.post('/LiveStreams/Close', queryParameters: {'liveStreamId': liveStreamId});
      throwIfHttpError(response);
    } catch (error, stackTrace) {
      appLogger.w('Failed to close a ${dialect.productName} live stream', error: error, stackTrace: stackTrace);
    }
  }

  @override
  LiveTvSupport get liveTv => _JellyfinLiveTvSupport(this as JellyfinClient);
}

/// Adapter from [LiveTvSupport] to MediaBrowser channel/program helpers.
class _JellyfinLiveTvSupport implements LiveTvSupport {
  final JellyfinClient _client;
  _JellyfinLiveTvSupport(this._client);

  @override
  LiveTvDvrSupport? get dvr => _JellyfinLiveTvDvrSupport(_client);

  @override
  Future<bool> isAvailable() => _client.hasLiveTv();

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) => _client.fetchLiveTvChannels();

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) {
    int? toEpoch(DateTime? dt) => dt == null ? null : dt.millisecondsSinceEpoch ~/ 1000;
    return _client.fetchLiveTvPrograms(beginsAt: toEpoch(from), endsAt: toEpoch(to));
  }

  /// Request HLS using this dialect's live profile, preserving codec-copy
  /// permission and the selected bitrate ceiling. Only an inspected EVENT
  /// media playlist can subsequently supply retained-history seeking.
  Future<LiveTvStreamResolution?> _resolveStreamUrl(
    String channelKey, {
    required TranscodeQualityPreset quality,
  }) async {
    // Both dialects negotiate HLS for server-retained history. Copy remains
    // permitted: an HLS TranscodingUrl can be a remux, not an encode.
    final info = await _client.getPlaybackInfo(
      channelKey,
      isLiveTv: true,
      // A posted MediaBrowser DeviceProfile defaults an omitted
      // MaxStreamingBitrate to 8 Mbps. Keep Original on Plezy's normal
      // 100 Mbps negotiation ceiling: it stays above the server's 40 Mbps
      // unknown-live estimate without inheriting that implicit 8 Mbps cap.
      maxStreamingBitrate: quality.isOriginal ? 100_000_000 : (quality.videoBitrateKbps ?? 100_000) * 1000,
      autoOpenLiveStream: true,
      enableDirectPlay: false,
      enableDirectStream: false,
      enableTranscoding: true,
      allowVideoStreamCopy: true,
      allowAudioStreamCopy: true,
    );
    final sources = info['MediaSources'] as List;
    if (sources.isEmpty) return null;
    final firstSource = sources.first;
    if (firstSource is! Map<String, dynamic>) {
      throw PlaybackException(
        t.liveTv.invalidPlaybackData(product: _client.dialect.productName),
        reason: PlaybackFailureReason.invalidPlaybackData,
      );
    }
    final source = firstSource;

    String? nonEmptyString(dynamic raw) => raw is String && raw.isNotEmpty ? raw : null;

    var playSessionId = nonEmptyString(info['PlaySessionId']);
    var mediaSourceId = nonEmptyString(source['Id']);
    var liveStreamId = nonEmptyString(source['LiveStreamId']);

    final rawUrl = nonEmptyString(source['TranscodingUrl']);
    final rawUri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (rawUrl == null || rawUri == null || !rawUri.path.toLowerCase().endsWith('.m3u8')) {
      appLogger.w('${_client.dialect.productName} Live TV negotiation returned no HLS transcode URL');
      // AutoOpenLiveStream already opened the tuner; bailing without a
      // session means no stop report will ever release it.
      if (liveStreamId != null) {
        unawaited(_client._closeLiveStream(liveStreamId));
      }
      return null;
    }
    final url = _client._withApiKey(rawUrl);
    final query = Uri.tryParse(url)?.queryParameters;
    playSessionId ??= query?['PlaySessionId'];
    mediaSourceId ??= query?['MediaSourceId'];
    liveStreamId ??= query?['LiveStreamId'];
    return LiveTvStreamResolution(
      url: url,
      playSessionId: playSessionId,
      mediaSourceId: mediaSourceId,
      liveStreamId: liveStreamId,
      playMethod: 'Transcode',
    );
  }

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async {
    final resolution = await _resolveStreamUrl(channelKey, quality: quality);
    if (resolution == null) return null;
    return _JellyfinLiveTvPlaybackSession(_client, channelKey, resolution);
  }

  /// SharedPreferences key for the locally-persisted favorite-channel list.
  /// Keyed by the compound connection id (`{machineId}/{userId}`) so users on
  /// the same MediaBrowser server don't share favorites.
  // Keep the legacy prefix: the connection id isolates both dialects, and changing it would lose Jellyfin ordering.
  String get _favoritesPrefsKey => 'jellyfin_fav_channels:${_client.connection.id}';

  /// Legacy bare-machineId key, kept for one-shot migration.
  String get _legacyFavoritesPrefsKey => 'jellyfin_fav_channels:${_client.serverId}';

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => 'server://${_client.serverId}/jellyfin';

  @override
  String get favoriteStoreKey => 'jellyfin:${_client.connection.id}';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  Future<List<FavoriteChannel>> _readPersistedFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) =>
      _client._favoritesRepository.read(
        key: _favoritesPrefsKey,
        legacyKey: _legacyFavoritesPrefsKey,
        migrate: migrate,
        checkCurrent: checkCurrent,
      );

  /// Local list is the source of truth (preserves order + display fields).
  /// Server-side `IsFavorite` is mirrored on writes via [setFavoriteChannels].
  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) =>
      _readPersistedFavoriteChannels(migrate: migrate, checkCurrent: checkCurrent);

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
    final previous = await _readPersistedFavoriteChannels(checkCurrent: checkCurrent);
    final previousIds = previous.map((channel) => channel.id).toSet();
    final requestedIds = channels.map((channel) => channel.id).toSet();
    final confirmedIds = {...previousIds};
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> applyMutation(String id, bool isFavorite) async {
      checkCurrent?.call();
      try {
        await _client._setItemFavorite(id, isFavorite);
        if (isFavorite) {
          confirmedIds.add(id);
        } else {
          confirmedIds.remove(id);
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        appLogger.w(
          'Failed to update a ${_client.dialect.productName} favorite channel',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    for (final id in requestedIds.difference(previousIds)) {
      await applyMutation(id, true);
    }
    for (final id in previousIds.difference(requestedIds)) {
      await applyMutation(id, false);
    }

    final confirmed = <FavoriteChannel>[
      for (final channel in channels)
        if (confirmedIds.contains(channel.id)) channel,
      for (final channel in previous)
        if (!requestedIds.contains(channel.id) && confirmedIds.contains(channel.id)) channel,
    ];
    checkCurrent?.call();
    await _client._favoritesRepository.write(_favoritesPrefsKey, confirmed, checkCurrent: checkCurrent);

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}

/// One MediaBrowser HLS job with its reporting identity and validated EVENT
/// history. Jellyfin and Emby retain their dialect-specific device profiles;
/// neither receives Plex URL-offset parameters.
class _JellyfinLiveTvPlaybackSession implements LiveTvPlaybackSession, LiveTvHlsTimeshiftSession {
  final JellyfinClient _client;
  final String _channelKey;
  final String _url;
  final JellyfinLiveSessionTracker _tracker;
  final _history = RetainedHlsHistory();
  Future<void>? _refreshingHistory;
  bool _preparedHistory = false;
  bool _retryHistory = false;
  bool _stopped = false;
  String? _originSegmentIdentity;
  String? _initializationIdentity;
  int? _loggedSegmentCount;

  // Jellyfin's output-file key includes User-Agent. Metadata and MPV must
  // name the very same job, including through same-URL player reloads.
  @override
  Map<String, String> get playbackHeaders => const {'User-Agent': 'Plezy-Live-HLS/1', 'Accept-Language': 'en'};

  Future<void> _refreshHistory({Duration timeout = const Duration(seconds: 5)}) =>
      _refreshingHistory ??= _readHistory(timeout).whenComplete(() => _refreshingHistory = null);

  Future<void> _readHistory(Duration timeout) async {
    if (_stopped) return;
    _retryHistory = false;
    try {
      var unsupported = false;
      final snapshot = await fetchLiveHlsManifest(Uri.parse(_url), (uri) async {
        final response = await _client._http.get(
          _client._withApiKey(uri.toString()),
          headers: {...playbackHeaders, 'Accept': 'application/vnd.apple.mpegurl', 'Cache-Control': 'no-cache'},
          timeout: timeout,
        );
        if (response.statusCode != 200 || response.data is! String) {
          _retryHistory = response.statusCode == 404 || response.statusCode == 408 || response.statusCode >= 500;
          appLogger.d('${_client.dialect.productName} retained HLS manifest unavailable: HTTP ${response.statusCode}');
          return null;
        }
        // Redirects must not silently change the playlist-relative base.
        if (response.effectiveUri != null && response.effectiveUri != response.requestUri) {
          appLogger.d('${_client.dialect.productName} retained HLS manifest redirected; history unavailable');
          return null;
        }
        return response.data as String;
      }, onUnsupported: () => unsupported = true);
      if (_stopped) return;
      if (snapshot == null) {
        if (unsupported) appLogger.d('${_client.dialect.productName} retained HLS playlist shape unsupported');
        if (unsupported && _history.playlist != null) {
          invalidateHistory();
        } else {
          _history.unavailable();
        }
      } else {
        if (!_history.update(snapshot, DateTime.now())) {
          appLogger.d('${_client.dialect.productName} retained HLS origin is retired');
        } else if (_loggedSegmentCount != snapshot.segments.length) {
          _loggedSegmentCount = snapshot.segments.length;
          final buffer = _history.buffer(DateTime.now());
          appLogger.d(
            '${_client.dialect.productName} retained HLS history: '
            'segments=${snapshot.segments.length}, duration=${snapshot.duration}, '
            'targetDuration=${snapshot.targetDuration}, seekEnd=${buffer?.seekEndSeconds}, '
            'preferredLive=${snapshot.preferredLivePosition}',
          );
        }
      }
    } catch (error) {
      _retryHistory = error is MediaServerHttpException && !error.isCancellation;
      final reason = error is MediaServerHttpException ? error.type.name : error.runtimeType.toString();
      appLogger.d('${_client.dialect.productName} retained HLS manifest request failed: $reason');
      _history.unavailable();
    }
  }

  @override
  void invalidateHistory() => _history.invalidate();

  /// Validate the actual files without buffering media in Dart. In particular,
  /// a restarted server job may reuse the same URL and segment names. Its first
  /// file validator must still match before a player reopen reuses the clock.
  Future<String?> _segmentIdentity(Uri uri) async {
    final abort = Completer<void>();
    try {
      final request = http.AbortableRequest(
        'GET',
        Uri.parse(_client._withApiKey(uri.toString())),
        abortTrigger: abort.future,
      )..followRedirects = false;
      request.headers.addAll({..._client._http.defaultHeaders, ...playbackHeaders, 'Range': 'bytes=0-0'});
      final response = await _client._http.inner.send(request).timeout(const Duration(seconds: 5));
      await response.stream.listen((_) {}).cancel();
      if (response.statusCode != 200 && response.statusCode != 206) {
        appLogger.d('${_client.dialect.productName} retained HLS file unavailable: HTTP ${response.statusCode}');
        return null;
      }
      final etag = response.headers['etag'];
      final modified = response.headers['last-modified'];
      // No validator means no evidence that a same-named origin survived.
      if (etag == null && modified == null) {
        appLogger.d('${_client.dialect.productName} retained HLS file lacks an identity validator');
        return null;
      }
      return '${etag ?? ''}|${modified ?? ''}';
    } catch (_) {
      return null;
    } finally {
      abort.complete();
    }
  }

  Future<bool> _validateFiles(double seconds) async {
    final snapshot = _history.playlist;
    if (snapshot == null) return false;
    final initialization = snapshot.initialization;
    if (initialization != null) {
      final identity = await _segmentIdentity(Uri.parse(initialization));
      if (identity == null || (_initializationIdentity != null && _initializationIdentity != identity)) {
        invalidateHistory();
        return false;
      }
      _initializationIdentity = identity;
    }
    final origin = await _segmentIdentity(snapshot.segments.first.uri);
    if (_stopped || origin == null || (_originSegmentIdentity != null && _originSegmentIdentity != origin)) {
      invalidateHistory();
      return false;
    }
    _originSegmentIdentity = origin;
    var elapsed = 0.0;
    for (final segment in snapshot.segments) {
      if (elapsed + segment.duration > seconds) {
        if (segment != snapshot.segments.first && await _segmentIdentity(segment.uri) == null) {
          invalidateHistory();
          return false;
        }
        return !_stopped && _history.isFresh(DateTime.now());
      }
      elapsed += segment.duration;
    }
    return false;
  }

  LiveTvSeekRequest _historyRequest(double seconds) => LiveTvSeekRequest(
    url: _client._withApiKey(_history.playlist!.uri.toString()),
    effectiveTargetEpoch: _history.epochOrigin! + seconds,
    mediaStart: Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round()),
    mediaEpochOrigin: _history.epochOrigin,
    mediaFirstSegmentEnd: Duration(
      microseconds: (_history.playlist!.segments.first.duration * Duration.microsecondsPerSecond).round(),
    ),
  );

  @override
  Future<LiveTvSeekRequest?> preparePlayback() async {
    await _refreshHistory();
    if (!_stopped && !_preparedHistory && !_history.isRetired && _retryHistory) {
      // A cold Live TV job can serve its master before FFmpeg has produced the
      // first media playlist. The regular polling deadline is too short for
      // that startup. Retry the same negotiation with a bounded warmup budget
      // before opening MPV, so a transient timeout cannot silently select an
      // unanchored player source for the entire session.
      appLogger.d('${_client.dialect.productName} waiting for retained HLS startup (30-second retry)');
      await _refreshHistory(timeout: const Duration(seconds: 30));
    }
    final snapshot = _history.playlist;
    if (_stopped || snapshot == null || !_history.isFresh(DateTime.now()) || _history.epochOrigin == null) {
      appLogger.d('${_client.dialect.productName} opening live playback without a validated HLS history');
      return null;
    }
    _preparedHistory = true;
    final seconds = snapshot.preferredLivePosition;
    if (!await _validateFiles(seconds)) return null;
    appLogger.d(
      '${_client.dialect.productName} retained HLS open: '
      'position=$seconds, segments=${snapshot.segments.length}, clock=${_history.exactClock ? 'PDT' : 'estimated'}',
    );
    return _historyRequest(seconds);
  }

  @override
  LiveTvSeekWindow? seekWindow(CaptureBuffer buffer) {
    final current = captureBuffer;
    if (current == null || buffer.startedAt != current.startedAt) return null;
    return LiveTvSeekWindow(
      startEpoch: current.startedAt + current.seekStartSeconds,
      // Whole-second targets strictly inside completed media, never its EOF.
      endEpoch: current.startedAt + current.seekEndSeconds.ceil() - 1,
    );
  }

  @override
  Future<LiveTvSeekRequest?> resolveSeek({
    required double? targetEpoch,
    required CaptureBuffer buffer,
    MediaSubtitleTrack? subtitleTrack,
  }) async {
    if (subtitleTrack != null || !_preparedHistory) return null;
    await _refreshHistory();
    final window = seekWindow(buffer);
    final target = targetEpoch == null ? (window == null ? null : preferredLiveEpoch) : window?.target(targetEpoch);
    if (target == null) return null;
    final seconds = target - _history.epochOrigin!;
    if (!await _validateFiles(seconds)) return null;
    appLogger.d('${_client.dialect.productName} retained HLS seek: position=$seconds');
    return _historyRequest(seconds);
  }

  _JellyfinLiveTvPlaybackSession(this._client, this._channelKey, LiveTvStreamResolution resolution)
    : _url = resolution.url,
      _tracker = JellyfinLiveSessionTracker(
        playSessionId: resolution.playSessionId,
        mediaSourceId: resolution.mediaSourceId,
        liveStreamId: resolution.liveStreamId,
        playMethod: resolution.playMethod,
      );

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.stopAndExit;

  @override
  CaptureBuffer? get captureBuffer => _stopped || !_preparedHistory ? null : _history.buffer(DateTime.now());

  @override
  double? get preferredLiveEpoch =>
      captureBuffer == null ? null : _history.epochOrigin! + _history.playlist!.preferredLivePosition;

  /// Intentionally unsupported: the session plays one URL negotiated at
  /// start, so there is no rebuild through which a server-side subtitle
  /// selection could be delivered. Jellyfin's live transcode profile decides
  /// subtitle handling on its own.
  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  bool get canTimeShift => false;

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async =>
      offsetSeconds == null && subtitleTrack == null ? _url : null;

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async {
    if (state == 'stopped') {
      _stopped = true;
      invalidateHistory();
    }
    await _tracker.report(
      client: _client,
      itemId: _channelKey,
      state: state,
      position: Duration(milliseconds: positionMs),
      duration: Duration(milliseconds: durationMs),
    );
    if (!_stopped && _preparedHistory) await _refreshHistory();
    return LiveTimelineUpdate(
      captureBuffer: captureBuffer,
      clearCaptureBuffer: captureBuffer == null,
      clearPlaybackClock: _history.isRetired,
    );
  }

  /// Reopen the existing negotiation without sending stop or closing the
  /// live stream. preparePlayback revalidates the playlist and origin file;
  /// lost history cannot inherit a replacement job's timing.
  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) async =>
      _stopped ? null : this;
}
