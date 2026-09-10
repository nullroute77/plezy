part of '../../video_player_screen.dart';

const _liveClockReadyTimeout = Duration(seconds: 15);

extension _VideoPlayerLiveTvMethods on VideoPlayerScreenState {
  /// Start periodic timeline heartbeats for live TV transcode session.
  void _startLiveTimelineUpdates() {
    if (_shuttingDown) return;
    _live.timelineOpenSuspension = null;
    if (_live.resumeTimelineOnResume) return;
    final generation = ++_live.timelineGeneration;
    _live.timelineTimer?.cancel();
    unawaited(_refreshLiveGuide());
    _live.timelineTimer = startLiveTimelinePolling(
      // Plex supplies seekable bounds in heartbeat responses. Refresh those
      // alongside playback rather than holding a ten-second-old buffer edge.
      interval: Duration(seconds: _live.session is LiveTvTimeshiftSession ? 2 : 10),
      isCurrent: () => mounted && generation == _live.timelineGeneration,
      onTick: () {
        _setPlayerState(() {}); // Refresh age-based availability, including paused playback.
        unawaited(_refreshLiveGuide());
      },
      report: () {
        final state = player?.state.playing == true ? 'playing' : 'paused';
        return _sendLiveTimeline(state);
      },
    );
  }

  /// Advance the fallback ladder and retry — the error path's entry point.
  void _beginLiveLadderRetry() {
    if (_shuttingDown) return;
    _live.fallbackLevel++;
    _live.retrying = true;
    appLogger.w('Live stream failed, retrying with fallback level ${_live.fallbackLevel}');
    unawaited(_retryLiveStream());
  }

  /// Play pressed while the live stream is dead: reuse the ladder retry
  /// unless one is already in flight.
  Future<void> _retryLiveStreamForPlayIntent() {
    if (_shuttingDown || _live.retrying) return Future.value();
    _live.retrying = true;
    return _retryLiveStream();
  }

  /// A playback restart proves the current ladder level works; refill it.
  void _resetLiveLadderOnPlaybackRestart() {
    _live.fallbackLevel = 0;
    _live.retryFailed = false;
  }

  void _suspendLiveTimelineForBackground() {
    final openOwner = _live.timelineOpenSuspension;
    _live.resumeTimelineOnResume = _live.resumeTimelineOnResume || _live.timelineTimer != null || openOwner != null;
    _stopLiveTimelineUpdates();
    _live.timelineOpenSuspension = openOwner;
  }

  void _resumeLiveTimelineAfterBackgroundIfNeeded() {
    final shouldResume = _live.resumeTimelineOnResume;
    _live.resumeTimelineOnResume = false;
    if (shouldResume && _live.session != null && _live.timelineOpenSuspension == null) {
      _startLiveTimelineUpdates();
    }
  }

  /// The TV background policy stopped the tuned session: exit the screen on
  /// the next resume instead of showing a dead stream.
  void _stopLiveSessionForTvBackground() {
    _live.exitOnResume = true;
    _live.resumeTimelineOnResume = false;
    _stopLiveTimelineUpdates();
  }

  /// Whether the background stop asked for an exit-on-resume; consuming the
  /// flag so the exit runs once.
  bool _consumeLiveExitOnResume() {
    if (!_live.exitOnResume) return false;
    _live.exitOnResume = false;
    return true;
  }

  void _stopLiveTimelineUpdates() {
    _live.timelineOpenSuspension = null;
    _live.timelineGeneration++;
    _live.timelineTimer?.cancel();
    _live.timelineTimer = null;
  }

  // Transfer an existing suspension to a newer operation as well as fencing
  // any in-flight heartbeat. Only its current owner may restore polling.
  int? _suspendLiveTimelineForOpen() {
    final wasRunning = _live.timelineTimer != null || _live.timelineOpenSuspension != null;
    _stopLiveTimelineUpdates();
    return _live.timelineOpenSuspension = wasRunning ? _live.timelineGeneration : null;
  }

  void _resumeLiveTimelineAfterOpen(int? owner) {
    if (owner != null && owner == _live.timelineOpenSuspension && mounted && !_shuttingDown) {
      _live.timelineOpenSuspension = null;
      if (!_live.resumeTimelineOnResume) _startLiveTimelineUpdates();
    }
  }

  Future<void> _sendLiveTimeline(String state) async {
    if (_shuttingDown && state != 'stopped') return;
    final requestSession = _live.session;
    if (requestSession == null) return;
    final requestGeneration = _live.timelineGeneration;
    final requestStreamGeneration = _live.streamGeneration;
    // For live TV, player position/duration are unreliable (often 0). Use
    // elapsed wall-clock as the position and the program duration from tune
    // metadata; the per-backend session owns the wire mapping.
    final playbackTime = requestSession is LiveTvHlsTimeshiftSession
        ? (player?.currentPosition.inMilliseconds ?? 0)
        : _live.playbackElapsed.elapsedMilliseconds;

    try {
      await _live.timelineReports.send(
        stopped: state == 'stopped',
        report: () => runLiveTimelineReport(
          requestSession: requestSession,
          requestGeneration: requestGeneration,
          state: state,
          positionMs: playbackTime,
          currentSession: () => _live.session,
          currentGeneration: () => _live.timelineGeneration,
          isMounted: () => mounted,
          commit: (update) {
            if (requestStreamGeneration != _live.streamGeneration) return;
            _setPlayerState(() {
              final playbackStream = update.playbackStream;
              if (playbackStream != null &&
                  _live.adoptPlaybackStreamOrigin(playbackStream, generation: requestStreamGeneration)) {
                appLogger.d('Live clock re-anchored on playback transcode origin ${playbackStream.startedAt}');
              }
              final buffer = update.captureBuffer;
              if (update.clearPlaybackClock) _live.invalidatePlayback();
              if (update.clearCaptureBuffer) _live.captureBuffer = null;
              if (buffer != null) {
                _live.captureBuffer = buffer;
                _liveBufferAge
                  ..reset()
                  ..start();
              }
              if (requestSession is LiveTvHlsTimeshiftSession) {
                appLogger.d(
                  'Retained HLS timeline: bufferEnd=${_live.captureBuffer?.seekEndSeconds}, '
                  'seekEnabled=${_liveSeekBounds() != null}, clockActive=${_live.activeClockSourceId != null}',
                );
              }
            });
          },
        ),
      );
    } catch (e) {
      appLogger.d('Live timeline update failed', error: e);
    }
  }

  /// Fire-and-forget a stopped heartbeat for a session that started but was
  /// never adopted (unmount or superseded mid-start) so the backend tears
  /// down its tuner/transcode resources instead of waiting for a timeout.
  void _abandonLiveSession(LiveTvPlaybackSession session) {
    unawaited(() async {
      try {
        await session.reportTimeline(state: 'stopped', positionMs: 0, durationMs: session.program.durationMs ?? 0);
      } catch (e) {
        appLogger.d('Failed to stop abandoned live session', error: e);
      }
    }());
  }

  /// Resolve the owning live-TV server for [channel] and start a playback
  /// session on it — the shared resolution path for initial launch and
  /// channel zapping (Plex tunes a DVR, Jellyfin negotiates a direct URL).
  Future<LiveTvPlaybackSession?> _startLiveSession(LiveTvChannel channel) async {
    final multiServer = context.read<MultiServerProvider>();
    final serverInfo = liveTvServerInfoForChannel(multiServer, channel);
    if (serverInfo == null) {
      appLogger.w('No live TV server available for ${channel.displayName}');
      return null;
    }
    final client = multiServer.getClientForServer(ServerId(serverInfo.serverId));
    if (client == null) {
      appLogger.w('Live TV server ${serverInfo.serverId} is not connected');
      return null;
    }
    return client.liveTv.startPlayback(channel.key, dvrKey: serverInfo.dvrKey, quality: _selectedQualityPreset);
  }

  /// Retry the live stream with degraded direct-stream settings.
  ///
  /// The session owns the per-backend recovery: Plex re-tunes the channel
  /// for a fresh capture session (the previous one expires while MPV
  /// exhausts its reconnect attempts) applying the degradation flags;
  /// Jellyfin/Emby reopen their negotiated HLS session.
  Future<void> _retryLiveStream() async {
    _liveSeek.cancel();
    final currentPlayer = player;
    if (!mounted || _shuttingDown || currentPlayer == null) return;
    final generation = _transitionGate.generation;
    final intent = _liveSeek.intentGeneration;
    final retryOwner = _live.beginRetry();
    final session = _live.session;
    bool isCurrent() =>
        _isCurrentPlaybackGeneration(generation, currentPlayer) &&
        identical(_live.session, session) &&
        intent == _liveSeek.intentGeneration &&
        _live.ownsRetry(retryOwner);
    _live.playbackPosition(currentPlayer.currentPosition);
    _live.invalidatePlayback();
    if (session == null) {
      _live.finishRetry(retryOwner);
      appLogger.w('Cannot retry live stream — no session');
      showGlobalErrorSnackBar(_redactPlayerError(_lastLogError ?? t.liveTv.liveStreamFailed));
      unawaited(_handleBackButton());
      return;
    }

    final ds = _live.fallbackLevel < 1;
    final dsa = _live.fallbackLevel < 2;
    appLogger.i('Retrying live stream: directStream=$ds directStreamAudio=$dsa');

    // Carried across the re-tune: stream ids are tune-scoped, so the choice
    // is re-mapped onto the recovered session's track list. Recovering the
    // video outranks keeping subtitles — a failed burn re-apply drops them.
    MediaSubtitleTrack? recoveredSubtitle;
    CaptureBuffer? recoveredCaptureBuffer;
    var timelineSuspension = _live.timelineOpenSuspension == null ? null : _suspendLiveTimelineForOpen();
    await runLiveStreamRetry<LiveTvPlaybackSession>(
      recover: () => session.recover(directStream: ds, directStreamAudio: dsa),
      lookupStreamUrl: (recovered) async {
        recoveredCaptureBuffer = recovered.captureBuffer;
        recoveredSubtitle = LiveTvSessionState.remapSubtitleSelection(recovered.subtitleTracks, _live.selectedSubtitle);
        if (recoveredSubtitle != null) {
          final url = await recovered.streamUrlAt(subtitleTrack: recoveredSubtitle);
          if (url != null) return url;
          appLogger.w('Live recovery could not re-apply the subtitle burn; retrying without subtitles');
          recoveredSubtitle = null;
        }
        return recovered.streamUrlAt();
      },
      applyPlayerOptions: () => _setLiveStreamOptions(currentPlayer),
      open: (recovered, streamUrl) async {
        final buffer = recoveredCaptureBuffer;
        return _openLiveStream(
          currentPlayer,
          streamUrl,
          session: recovered,
          targetEpoch: buffer == null ? null : buffer.startedAt + buffer.seekEndSeconds,
          applyOptions: false,
          isCurrent: isCurrent,
          onOpenStarted: () {
            timelineSuspension = _suspendLiveTimelineForOpen();
          },
        );
      },
      isCurrent: isCurrent,
      adoptSession: (recovered) {
        _live.adoptSession(recovered);
        _live.playbackElapsed
          ..reset()
          ..start();
        _live.selectedSubtitle = recoveredSubtitle;
        _live.retryFailed = false;
      },
      // Jellyfin's recover() returns the receiver, so the recovered object can
      // be the still-current session; the retry helper skips the discard by
      // identity so a failed retry cannot terminally stop-report it.
      currentSession: () => _live.session,
      discardSession: _abandonLiveSession,
      reportFailure: (error, stackTrace) {
        appLogger.e('Failed to recover live stream', error: error, stackTrace: stackTrace);
        _live.retryFailed = true;
        showGlobalErrorSnackBar(t.messages.liveStreamInterrupted);
      },
      onFinished: () {
        // Intent/session supersession may invalidate adoption, but the retry
        // still releases its own flag. It cannot release a newer retry.
        _live.finishRetry(retryOwner);
        if (_isCurrentPlaybackGeneration(generation, currentPlayer)) {
          _resumeLiveTimelineAfterOpen(timelineSuspension);
        }
      },
    );
  }

  /// Configure MPV options for live streaming.
  /// The official Plex Media Player does not set client-side reconnect options —
  /// reconnection is handled by the server's transcoder on the input side.
  Future<void> _setLiveStreamOptions(Player player) => player.setProperty('force-seekable', 'no');

  /// Re-opens the current session's live stream at [streamUrl].
  ///
  /// Offset-based MPV opens register their requested absolute [targetEpoch]
  /// before `loadfile` and bind that registration to the source id the load
  /// reports, so only that source's events can calibrate it. When [awaitClock]
  /// is true, success means the new source's first rendered player position
  /// has been mapped to that epoch.
  Future<bool> _openLiveStream(
    Player player,
    String streamUrl, {
    required LiveTvPlaybackSession session,
    required bool Function() isCurrent,
    double? targetEpoch,
    bool awaitClock = false,
    bool? play,
    bool applyOptions = true,
    bool timeShifted = false,
    LiveTvSeekRequest? hlsRequest,
    void Function()? onOpenStarted,
  }) async {
    bool ownsOpen() => mounted && !_shuttingDown && _launchCurrent && this.player == player && isCurrent();
    if (!ownsOpen()) return false;
    final hls = session is LiveTvHlsTimeshiftSession ? session as LiveTvHlsTimeshiftSession : null;
    if (hls != null && player is PlayerNative) {
      hlsRequest ??= await hls.preparePlayback();
      if (!ownsOpen()) return false;
      if (hlsRequest != null) {
        streamUrl = hlsRequest.url;
        targetEpoch = hlsRequest.effectiveTargetEpoch;
        timeShifted = true;
        awaitClock = true;
      } else {
        // An unanchored live fallback must not inherit an older HLS epoch.
        targetEpoch = null;
        timeShifted = false;
        awaitClock = false;
      }
    }
    if (applyOptions) await _setLiveStreamOptions(player);
    if (!ownsOpen()) return false;
    _live.playbackPosition(player.currentPosition);
    _live.invalidatePlayback();
    _live.clockSession = session;
    _live.streamGeneration++;
    final streamGeneration = _live.streamGeneration;
    bool ownsStream() => ownsOpen() && streamGeneration == _live.streamGeneration;
    final media = Media(
      streamUrl,
      start: hlsRequest?.mediaStart,
      headers: hls?.playbackHeaders ?? const {'Accept-Language': 'en'},
    );
    // The native playing flag also goes false on buffering/failure. Preserve
    // the user's latest pause/play intent through automatic HLS recovery too.
    final playNow = (play ?? automotivePlaybackAllowedNow()) && (hls == null || _playbackIntentShouldPlay);
    if (targetEpoch == null || player is! PlayerNative) {
      if (!ownsStream()) return false;
      onOpenStarted?.call();
      if (player is PlayerNative) {
        final sourceId = await player.open(media, play: playNow, isLive: true);
        if (sourceId == null) return false;
      } else {
        await player.open(media, play: playNow, isLive: true);
      }
      if (ownsStream() && targetEpoch != null) {
        _live.estimateUnidentifiedStream(targetEpoch, player.currentPosition);
      }
      return ownsStream();
    }

    final clockGeneration = _live.beginClockOpen(
      targetEpoch,
      mediaStart: hlsRequest?.mediaStart,
      mediaEpochOrigin: hlsRequest?.mediaEpochOrigin,
      mediaFirstSegmentEnd: hlsRequest?.mediaFirstSegmentEnd,
    );
    final clockResult = _live.clockOpenResult(clockGeneration);
    final int? sourceId;
    try {
      if (!ownsStream()) {
        _live.failClockOpen(clockGeneration);
        return false;
      }
      onOpenStarted?.call();
      sourceId = await player.open(
        media,
        play: playNow,
        isLive: true,
        startLivePlaylistFromBeginning: timeShifted,
        seekPreRoll: hlsRequest?.mediaSeekPreRoll,
      );
    } catch (_) {
      _live.failClockOpen(clockGeneration);
      rethrow;
    }
    if (!ownsStream()) {
      _live.failClockOpen(clockGeneration);
      return false;
    }
    if (sourceId == null) {
      // The load never reached mpv (core unavailable), so no source will ever
      // report for this open.
      _live.failClockOpen(clockGeneration);
      return false;
    }
    _live.bindClockOpen(clockGeneration, sourceId);

    if (!awaitClock) {
      unawaited(clockResult);
      return true;
    }
    final ready = await clockResult.timeout(
      _liveClockReadyTimeout,
      onTimeout: () {
        _live.timeoutClockOpen(clockGeneration);
        appLogger.w('Live time-shift source did not report a rendered clock position');
        return false;
      },
    );
    if (!ready && ownsStream() && hlsRequest != null) {
      hls?.invalidateHistory();
      if (identical(_live.session, session)) _live.captureBuffer = null;
    }
    if (ready && ownsStream() && identical(_live.session, session) && hlsRequest != null) {
      _live.captureBuffer = session.captureBuffer;
      _liveBufferAge
        ..reset()
        ..start();
    }
    return ready && ownsStream();
  }

  double? get _currentPositionEpoch =>
      _liveSeek.pendingEpoch ?? _live.playbackPosition(player?.currentPosition ?? Duration.zero).epoch;

  double? get _preferredLiveEpoch {
    final buffer = _live.captureBuffer;
    if (buffer == null) return null;
    final session = _live.session;
    return session is LiveTvHlsTimeshiftSession
        ? (session as LiveTvHlsTimeshiftSession).preferredLiveEpoch
        : buffer.startedAt + buffer.seekEndSeconds;
  }

  LiveTvTimeline _liveTimelineForPosition(Duration position) {
    final session = _live.session;
    final buffer = _live.captureBuffer;
    final staleBuffer = _liveBufferAge.isRunning && _liveBufferAge.elapsed > const Duration(seconds: 30);
    final engineSupported = session is! LiveTvHlsTimeshiftSession || player is PlayerNative;
    final seekable = engineSupported && session is LiveTvTimeshiftSession && buffer != null && !staleBuffer
        ? (session as LiveTvTimeshiftSession).seekWindow(buffer)
        : null;
    return LiveTvTimeline.resolve(
      playback: _live.playbackPosition(position),
      seekable: seekable,
      liveEdgeEpoch: _preferredLiveEpoch,
      liveEdgeAccuracy: buffer == null
          ? LiveTvTimeAccuracy.unknown
          : staleBuffer
          ? LiveTvTimeAccuracy.stale
          : LiveTvTimeAccuracy.estimated,
      pendingSeekEpoch: _liveSeek.pendingEpoch ?? _live.pendingTargetEpoch,
      programPreviewEpoch: _liveSeek.programPreviewEpoch,
      seekStatus: _liveSeek.pendingEpoch != null ? LiveTvSeekStatus.pending : _live.seekStatus,
      programs: identical(_liveGuideSession, session) ? _liveGuide.programs : const [],
      metadataNowEpoch: DateTime.now().millisecondsSinceEpoch / 1000.0,
      programDataStale: _liveGuide.stale || _liveGuideAge.elapsed > const Duration(minutes: 2),
    );
  }

  Future<void> _refreshLiveGuide() async {
    final session = _live.session;
    if (session == null || session is! LiveTvTimeshiftSession || !mounted) return;
    if (!identical(_liveGuideSession, session)) {
      _liveGuideSession = session;
      _liveGuide.reset(session);
      _liveGuideLoading = false;
      _liveGuideAge.reset();
      _liveBufferAge
        ..reset()
        ..start();
    } else if (_liveGuideLoading || (_liveGuideAge.isRunning && _liveGuideAge.elapsed < const Duration(minutes: 1))) {
      return;
    }
    final args = widget.live!;
    final channels = args.channels;
    final channel = channels != null && _live.channelIndex >= 0 && _live.channelIndex < channels.length
        ? channels[_live.channelIndex]
        : args.channel;
    final multiServer = context.read<MultiServerProvider>();
    final serverInfo = liveTvServerInfoForChannel(multiServer, channel);
    if (serverInfo == null) return;
    final client = multiServer.getClientForServer(ServerId(serverInfo.serverId));
    if (client == null) return;
    _liveGuideLoading = true;
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final buffer = _live.captureBuffer;
    final playback = _live.playbackPosition(player?.currentPosition ?? Duration.zero).epoch;
    var from = buffer == null ? now - 3600 : buffer.startedAt + buffer.seekStartSeconds;
    if (playback != null && playback < from) from = playback;
    final changed = await _liveGuide.refresh(
      owner: session,
      channel: channel,
      fromEpoch: from,
      toEpoch: now + 6 * 3600,
      fetch: (from, to) => client.liveTv.fetchSchedule(from: from, to: to),
    );
    if (!mounted || !identical(_live.session, session) || !identical(_liveGuideSession, session)) return;
    _liveGuideLoading = false;
    _liveGuideAge
      ..reset()
      ..start();
    if (changed) _setPlayerState(() {});
  }

  /// Show "Watch from Start" / "Watch Live" dialog.
  /// Returns true if user chose "Watch from start", false for "Watch Live", null if dismissed.
  Future<bool?> _showWatchFromStartDialog(int effectiveStartEpoch, int nowEpoch) {
    final minutesAgo = ((nowEpoch - effectiveStartEpoch) / 60).round();
    return showOptionPickerDialog<bool>(
      context,
      title: t.liveTv.joinSession,
      options: [
        (icon: Symbols.replay_rounded, label: t.liveTv.watchFromStart(minutes: minutesAgo), value: true),
        (icon: Symbols.live_tv_rounded, label: t.liveTv.watchLive, value: false),
      ],
    );
  }

  /// Translate the absolute seek through the backend, then open the resolved
  /// stream. Retained HLS uses a player offset within the same server job;
  /// Plex uses its existing server-positioned URL.
  Future<bool> _seekLivePosition(double? targetEpochSeconds, {PlaybackTransitionLease? sourceLease}) async {
    final currentPlayer = player;
    final session = _live.session;
    bool ownsTransition() => sourceLease == null
        ? _transitionGate.transition == PlaybackTransition.idle
        : _transitionGate.owns(sourceLease, expected: PlaybackTransition.switchingSource);
    if (currentPlayer == null ||
        session == null ||
        session is! LiveTvTimeshiftSession ||
        !ownsTransition() ||
        _live.retrying) {
      return false;
    }
    if (session is LiveTvHlsTimeshiftSession && currentPlayer is! PlayerNative) return false;
    final generation = _transitionGate.generation;
    final intent = _liveSeek.intentGeneration;
    bool isCurrent() =>
        _isCurrentPlaybackGeneration(generation, currentPlayer) &&
        identical(_live.session, session) &&
        intent == _liveSeek.intentGeneration &&
        ownsTransition() &&
        !_live.retrying;
    _live.seekStatus = LiveTvSeekStatus.pending;
    final result = await runLiveTvSeek(
      session: session as LiveTvTimeshiftSession,
      targetEpoch: targetEpochSeconds,
      currentBuffer: () => targetEpochSeconds == null ? _live.captureBuffer : _freshLiveBuffer,
      isCurrent: isCurrent,
      subtitleTrack: _live.selectedSubtitle,
      open: (request) async {
        if (!isCurrent()) return false;
        _live.playbackElapsed
          ..reset()
          ..start();
        return _openLiveStream(
          currentPlayer,
          request.url,
          session: session,
          targetEpoch: request.effectiveTargetEpoch,
          awaitClock: currentPlayer is PlayerNative,
          isCurrent: isCurrent,
          timeShifted: targetEpochSeconds != null,
          hlsRequest: request.mediaStart == null ? null : request,
          play: session is LiveTvHlsTimeshiftSession ? _playbackIntentShouldPlay : null,
        );
      },
    );
    if (result == LiveTvSeekOutcome.superseded || !isCurrent()) return false;
    if (result == LiveTvSeekOutcome.failed) {
      _live.synchronizeHistoryAvailability(session);
      _live.seekStatus = LiveTvSeekStatus.failed;
      showGlobalErrorSnackBar(t.liveTv.liveStreamFailed);
    }
    _setPlayerState(() {});
    return result == LiveTvSeekOutcome.opened;
  }

  /// Apply a source subtitle choice to the live stream by rebuilding it with
  /// the backend's server-side delivery (Plex points the part's selection at
  /// the stream and burns it). The live counterpart of the VOD source switch:
  /// same [PlaybackSourceSubtitleChoice], but the restart is the raw
  /// `streamUrlAt → open(isLive: true)` every live URL change uses.
  Future<PlaybackSourceChangeOutcome> _switchLiveSubtitle(
    PlaybackSourceSubtitleChoice choice,
    PlaybackTransitionLease lease,
  ) async {
    if (_live.retrying) return PlaybackSourceChangeOutcome.busy;
    _liveSeek.cancel();
    final currentPlayer = player;
    final session = _live.session;
    if (currentPlayer == null || session == null) return PlaybackSourceChangeOutcome.unavailable;

    MediaSubtitleTrack? target;
    if (!choice.isOff) {
      for (final track in session.subtitleTracks) {
        if (track.id == choice.sourceStreamId) {
          target = track;
          break;
        }
      }
      if (target == null) return PlaybackSourceChangeOutcome.unavailable;
    }
    final previous = _live.selectedSubtitle;
    if (target?.id == previous?.id) return PlaybackSourceChangeOutcome.unchanged;

    _live.selectedSubtitle = target;

    // Preserve the active position estimate even after a long live pause.
    // Last-open mode cannot establish where playback is now.
    if (_live.captureBuffer != null && _currentPositionEpoch != null) {
      if (_currentPositionEpoch != null && await _seekLivePosition(_currentPositionEpoch, sourceLease: lease)) {
        return PlaybackSourceChangeOutcome.applied;
      }
      if (!_transitionGate.owns(lease) || !identical(_live.session, session)) {
        return PlaybackSourceChangeOutcome.superseded;
      }
      _live.selectedSubtitle = previous;
      return PlaybackSourceChangeOutcome.failed;
    }

    final streamUrl = await session.streamUrlAt(subtitleTrack: target);
    if (!mounted || player != currentPlayer || _live.session != session) {
      return PlaybackSourceChangeOutcome.superseded;
    }
    if (streamUrl == null) {
      _live.selectedSubtitle = previous;
      return PlaybackSourceChangeOutcome.failed;
    }
    _live.markStreamRestartedAtLiveEdge(_live.captureBuffer);
    final opened = await _openLiveStream(
      currentPlayer,
      streamUrl,
      session: session,
      targetEpoch: _live.captureBuffer == null ? null : _live.streamStartEpoch,
      isCurrent: () => _transitionGate.owns(lease) && identical(_live.session, session),
    );
    if (!_transitionGate.owns(lease) || !identical(_live.session, session)) {
      return PlaybackSourceChangeOutcome.superseded;
    }
    if (!opened) _live.selectedSubtitle = previous;
    if (mounted) _setPlayerState(() {});
    return opened ? PlaybackSourceChangeOutcome.applied : PlaybackSourceChangeOutcome.failed;
  }

  /// Current seekable epoch window for [_liveSeek], or null when there is no
  /// live capture buffer.
  CaptureBuffer? get _freshLiveBuffer =>
      _liveBufferAge.isRunning && _liveBufferAge.elapsed > const Duration(seconds: 30) ? null : _live.captureBuffer;

  LiveSeekBounds? _liveSeekBounds() {
    if (_live.retrying) return null;
    final session = _live.session;
    if (session is LiveTvHlsTimeshiftSession && player is! PlayerNative) return null;
    final buffer = _freshLiveBuffer;
    if (session is! LiveTvTimeshiftSession || buffer == null) return null;
    final window = (session as LiveTvTimeshiftSession).seekWindow(buffer);
    return window;
  }

  void _onLiveSeekTargetChanged() {
    if (!mounted) return;
    if (_lastLiveIntent != _liveSeek.intentGeneration) {
      _lastLiveIntent = _liveSeek.intentGeneration;
      _live.cancelClockOpens();
    }
    _setPlayerState(() {});
  }

  /// Re-open the live stream at [targetEpochSeconds], logging failures.
  Future<bool> _runLiveSeek(double? targetEpochSeconds) async {
    final session = _live.session;
    final intent = _liveSeek.intentGeneration;
    try {
      final opened = await _seekLivePosition(targetEpochSeconds);
      if (!opened) {
        appLogger.w('Live time-shift seek did not reach a ready source');
      }
      return opened;
    } catch (e, st) {
      appLogger.w('Live time-shift seek failed', error: e, stackTrace: st);
      if (mounted && identical(_live.session, session) && intent == _liveSeek.intentGeneration) {
        if (session != null) _live.synchronizeHistoryAvailability(session);
        _live.seekStatus = LiveTvSeekStatus.failed;
        _setPlayerState(() {});
        showGlobalErrorSnackBar(t.liveTv.liveStreamFailed);
      }
      return false;
    }
  }

  /// Seek the live stream to an absolute epoch (scrubber / jump-to-live). Drops
  /// any pending relative-skip burst first so a queued seek can't override it.
  void _seekLiveToEpoch(double targetEpochSeconds) => _liveSeek.seekTo(targetEpochSeconds);

  /// Jump to the live edge of the capture buffer.
  void _jumpToLiveEdge() {
    if (_live.retrying) return;
    final target = _preferredLiveEpoch;
    if (target != null) _liveSeek.jumpToLive(previewEpoch: target);
  }

  Future<void> _switchLiveChannel(int delta) async {
    if (_shuttingDown) return;
    final channels = widget.live?.channels;
    if (channels == null || channels.isEmpty) return;
    final newIndex = _live.channelIndex + delta;
    if (newIndex < 0 || newIndex >= channels.length) return;
    final currentPlayer = player;
    if (currentPlayer == null) return;

    final transitionLease = _transitionGate.tryAcquire(PlaybackTransition.switchingChannel);
    if (transitionLease == null) return; // debounce concurrent switches
    final previousSession = _live.session;
    bool isCurrentChannelSwitch() =>
        mounted &&
        !_shuttingDown &&
        player == currentPlayer &&
        identical(_live.session, previousSession) &&
        _transitionGate.owns(transitionLease, expected: PlaybackTransition.switchingChannel);
    _liveSeek.cancel();
    _live.cancelRetry();

    final previousFirstFrame = _firstFrame.snapshot();
    final channel = channels[newIndex];
    appLogger.d('Switching to channel: ${channel.displayName} (${channel.key})');

    LiveTvPlaybackSession? session;
    var replacementOpenStarted = false;
    var timelineSuspension = _live.timelineOpenSuspension == null ? null : _suspendLiveTimelineForOpen();
    try {
      // Channel switch IS a fresh start: same resolution path as launch. Keep
      // the old session alive until the replacement stream is actually open so
      // a failed zap does not tell the server to reclaim the still-playing
      // tuner/transcode session.
      session = await _startLiveSession(channel);
      if (session == null) {
        // Jellyfin's negotiation returns null instead of throwing, so this
        // is not covered by the catch below; without feedback a failed zap
        // looks like a dead remote (#2198).
        if (mounted) showErrorSnackBar(context, t.liveTv.failedToStartChannel);
        return;
      }
      if (!isCurrentChannelSwitch()) {
        _abandonLiveSession(session);
        return;
      }

      final streamUrl = await session.streamUrlAt();
      if (streamUrl == null || !isCurrentChannelSwitch()) {
        _abandonLiveSession(session);
        return;
      }

      _setPlayerState(() {
        _firstFrame.reset();
      });
      final buffer = session.captureBuffer;
      final targetEpoch = buffer == null ? null : buffer.startedAt + buffer.seekEndSeconds;
      final opened = await _openLiveStream(
        currentPlayer,
        streamUrl,
        session: session,
        targetEpoch: targetEpoch,
        isCurrent: isCurrentChannelSwitch,
        onOpenStarted: () {
          replacementOpenStarted = true;
          timelineSuspension = _suspendLiveTimelineForOpen();
          // The native state belongs to the replacement from this point,
          // before its session/channel is adopted after timeline reporting.
          // Detach the receipt, not the screen's launch lifetime fence.
          widget.launchObserver?.detach();
        },
      );
      if (!isCurrentChannelSwitch()) {
        _abandonLiveSession(session);
        return;
      }

      if (!opened) throw StateError(t.liveTv.liveStreamFailed);

      // Polling is already suspended. Send the old terminal timeline before
      // adopting the replacement, keeping the suspension owned until then.
      if (previousSession != null) {
        await _sendLiveTimeline('stopped');
      }
      if (!isCurrentChannelSwitch()) {
        _abandonLiveSession(session);
        return;
      }

      _live.adoptSession(session);
      _live.playbackElapsed
        ..reset()
        ..start();
      _live.fallbackLevel = 0;
      _live.cancelRetry();
      _live.retryFailed = false;

      if (!mounted) return;
      _setPlayerState(() {
        _live.channelIndex = newIndex;
        _live.channelName = channel.displayName;
      });

      // Restart timeline heartbeats for the new session
      _startLiveTimelineUpdates();
    } catch (e) {
      // A session that tuned but was never adopted (streamUrlAt/open threw)
      // would otherwise hold its server-side tuner until the backend times out.
      final orphan = session;
      if (orphan != null && _live.session != orphan) _abandonLiveSession(orphan);
      if (!isCurrentChannelSwitch()) return;
      if (replacementOpenStarted && previousSession != null) {
        // The failed replacement may already own the native player. Keeping
        // the old session adopted is not enough: reload its actual stream.
        var restored = false;
        try {
          final previousUrl = await previousSession.streamUrlAt(subtitleTrack: _live.selectedSubtitle);
          if (previousUrl != null && isCurrentChannelSwitch()) {
            final buffer = previousSession.captureBuffer;
            restored = await _openLiveStream(
              currentPlayer,
              previousUrl,
              session: previousSession,
              targetEpoch: buffer == null ? null : buffer.startedAt + buffer.seekEndSeconds,
              isCurrent: isCurrentChannelSwitch,
            );
          }
        } catch (restoreError) {
          appLogger.w('Failed to restore previous live channel', error: restoreError);
        }
        if (!isCurrentChannelSwitch()) return;
        if (restored) {
          _live.retryFailed = false;
          _live.playbackElapsed
            ..reset()
            ..start();
        } else {
          _live.retryFailed = true;
          await currentPlayer.stop();
        }
      } else {
        _setPlayerState(() => _firstFrame.restore(previousFirstFrame));
      }
      appLogger.e('Failed to switch channel', error: e);
      if (mounted) showErrorSnackBar(context, e.toString());
    } finally {
      if (isCurrentChannelSwitch()) _resumeLiveTimelineAfterOpen(timelineSuspension);
      _transitionGate.release(transitionLease);
    }
  }

  bool get _hasNextChannel {
    final channels = widget.live?.channels;
    return channels != null && _live.channelIndex >= 0 && _live.channelIndex < channels.length - 1;
  }

  bool get _hasPreviousChannel => widget.live?.channels != null && _live.channelIndex > 0;
}
