import 'dart:async';
import 'package:clock/clock.dart';
import '../../../media/ids.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../focus/dpad_navigator.dart';
import '../../../focus/dpad_select_long_press_controller.dart';
import '../../../focus/focus_theme.dart';
import '../../../focus/input_mode_tracker.dart';
import '../../../focus/key_event_utils.dart';
import '../../../i18n/app_locale_utils.dart';
import '../../../i18n/strings.g.dart';
import '../../../mixins/mounted_set_state_mixin.dart';
import '../../../models/livetv_channel.dart';
import '../../../models/livetv_program.dart';
import '../../../models/media_grab_operation.dart';
import '../../../providers/multi_server_provider.dart';
import '../../../media/media_server_client.dart';
import '../../../theme/mono_tokens.dart';
import '../../../utils/app_logger.dart';
import '../live_tv_actions_mixin.dart';
import '../live_tv_refresh_mixin.dart';
import '../live_tv_server_iteration.dart';
import '../../../utils/formatters.dart';
import '../../../utils/live_tv_grouping.dart';
import '../../../utils/live_tv_matching.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/tone_mapped_logo_image.dart';
import '../../../widgets/status_pill.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/app_menu.dart';
import '../../../widgets/clickable_cursor.dart';
import '../../../widgets/optimized_media_image.dart';
import '../livetv_styles.dart';
import '../tv_guide_program_info.dart';

class GuideTab extends StatefulWidget {
  final List<LiveTvChannel> channels;
  final List<LiveTvChannel> favoriteChannels;
  final VoidCallback? onReorderFavorites;
  final bool Function(LiveTvChannel channel)? isFavoriteChannel;
  final void Function(LiveTvChannel)? onToggleFavorite;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onBack;

  const GuideTab({
    super.key,
    required this.channels,
    this.favoriteChannels = const [],
    this.onReorderFavorites,
    this.isFavoriteChannel,
    this.onToggleFavorite,
    this.onNavigateUp,
    this.onBack,
  });

  @override
  State<GuideTab> createState() => GuideTabState();
}

@visibleForTesting
({String channelScopeKey, ({String kind, String value})? programId, int? beginsAt, int? endsAt}) guideAiringIdentity(
  LiveTvChannel channel,
  LiveTvProgram program,
) {
  ({String kind, String value})? programId;
  if (program.ratingKey case final ratingKey? when ratingKey.isNotEmpty) {
    programId = (kind: 'ratingKey', value: ratingKey);
  } else if (program.guid case final guid? when guid.isNotEmpty) {
    programId = (kind: 'guid', value: guid);
  } else if (program.key case final key? when key.isNotEmpty) {
    programId = (kind: 'key', value: key);
  }

  // Keep the slot even with an ID so repeated airings cannot inherit each
  // other's hold; with no ID, channel scope plus timing is the fallback.
  return (
    channelScopeKey: liveTvChannelScopeKey(channel),
    programId: programId,
    beginsAt: program.beginsAt,
    endsAt: program.endsAt,
  );
}

/// Subtract within the current local half hour instead of reconstructing an
/// ambiguous wall-clock hour during the autumn daylight-saving transition.
@visibleForTesting
DateTime guideHalfHourStart(DateTime time) => time.subtract(
  Duration(
    minutes: time.minute % 30,
    seconds: time.second,
    milliseconds: time.millisecond,
    microseconds: time.microsecond,
  ),
);

enum _GuideZone { timeNav, favorites, grid }

typedef _GuideFocusSnapshot = ({
  bool hasFocus,
  _GuideZone zone,
  int timeNavIndex,
  int channelIndex,
  int gridColumn,
  LiveTvProgram? program,
});

sealed class _GuideRow {
  const _GuideRow();
}

final class _GuideSourceHeaderRow extends _GuideRow {
  final String label;
  final bool favorites;

  const _GuideSourceHeaderRow({required this.label, this.favorites = false});
}

final class _GuideChannelRow extends _GuideRow {
  final LiveTvChannel channel;
  final int channelIndex;

  const _GuideChannelRow({required this.channel, required this.channelIndex});
}

class GuideTabState extends State<GuideTab>
    with LiveTvActionsMixin<GuideTab>, MountedSetStateMixin, WidgetsBindingObserver, LiveTvRefreshMixin<GuideTab> {
  static const _slotWidth = 240.0;
  double get _channelColumnWidth => PlatformDetector.isMobile(context) ? 96.0 : 132.0;
  double _rowHeight = 64.0;
  final _hoverPreview = ValueNotifier<({LiveTvChannel channel, LiveTvProgram? program})?>(null);
  static const _sourceHeaderRowHeight = 40.0;
  static const _timeHeaderHeight = 40.0;
  static const _tvVisibleChannelRows = 6;
  static const _minutesPerSlot = 30;

  static const _followNowIdleDelay = Duration(seconds: 5);

  List<LiveTvProgram> _programs = [];
  Map<String, List<LiveTvProgram>> _programsByChannelScope = const {};
  Set<String> _scheduledRecordingKeys = const {};

  /// Recording keys the user just scheduled/unscheduled from this guide.
  /// Local actions stay authoritative until the next full grid load returns
  /// fresh subscription attributes: the grab refresh below races the server
  /// materializing (or tearing down) grab operations, and the rendered
  /// programs keep their stale `subscriptionID` attributes until refetched.
  Map<String, bool> _recordingOverrides = const {};
  bool _isLoading = true;

  /// Whether a load has completed at least once for this tab. Until the
  /// first successful load the guide shows a full-screen spinner; in-session
  /// window reloads keep the existing grid mounted and only overlay a
  /// lightweight loading indicator. Never reset on channel-list changes:
  /// `didUpdateWidget` re-indexes the loaded programs and fires no fetch, and
  /// a reset would restore the unmount (and D-pad focus loss) this flag fixes.
  bool _hasLoadedOnce = false;
  int _programLoadGeneration = 0;

  late DateTime _gridStart;
  late DateTime _gridEnd;

  final ScrollController _headerHorizontalController = ScrollController();
  final ScrollController _gridHorizontalController = ScrollController();
  final ScrollController _channelVerticalController = ScrollController();
  final ScrollController _gridVerticalController = ScrollController();
  bool _syncingScroll = false;

  final _gridSelectController = DpadSelectLongPressController();
  final _dayPickerKey = GlobalKey();

  // Follow half-hour boundaries until the user explicitly browses another
  // time. Keep channel navigation live, but defer moving cards during input.
  bool _followNow = true;
  DateTime? _lastGuideInteraction;
  final Set<int> _activePointers = {};
  Timer? _followNowTimer;

  // Focus state
  final FocusNode _guideFocusNode = FocusNode(debugLabel: 'guide_tab');
  _GuideZone _focusZone = _GuideZone.timeNav;
  int _timeNavIndex = 1; // 0=left arrow, 1=day picker, 2=right arrow
  int _gridChannelIndex = 0;
  bool _hasEnteredGrid = false;
  int _gridColumn = 0; // 0=channel, 1=program
  bool _hasFocus = false;
  final ValueNotifier<_GuideFocusSnapshot> _focusSnapshot = ValueNotifier((
    hasFocus: false,
    zone: _GuideZone.timeNav,
    timeNavIndex: 1,
    channelIndex: 0,
    gridColumn: 0,
    program: null,
  ));
  LiveTvProgram? _focusedProgram;
  bool _pendingFocus = false;

  @override
  List<LiveTvChannel> get liveTvChannels => widget.channels;

  // Jump requested while programs were still loading (guide search from
  // another tab lands on a freshly built guide) — replayed by _loadPrograms.
  LiveTvChannel? _pendingJumpChannel;
  LiveTvProgram? _pendingJumpProgram;

  /// A presentation change must retain the selected airing/channel. Ordinary
  /// tab entry deliberately starts at the first channel via [focusContent].
  void restoreFocusAfterPlayback() {
    if (!InputModeTracker.isKeyboardMode(context)) return;
    _guideFocusNode.requestFocus();
    _publishFocusSnapshot();
  }

  /// Focus into the guide content (called from tab bar navigation or initial load).
  void focusContent() {
    if (!InputModeTracker.isKeyboardMode(context)) return;
    // If still loading programs, defer until the Focus widget is in the tree.
    if (_isLoading) {
      _pendingFocus = true;
      return;
    }
    _pendingFocus = false;
    _guideFocusNode.requestFocus();
    _updateFocus(() {
      if (widget.channels.isNotEmpty) {
        _focusZone = _GuideZone.grid;
        _gridColumn = 0;
        _gridChannelIndex = _displayOrderChannelIndexes.first;
        _focusedProgram = null;
      } else {
        _focusZone = _GuideZone.timeNav;
        _timeNavIndex = 1;
      }
    });
  }

  /// Jump the guide to [channel] (from guide search): scroll to its row and
  /// land d-pad focus on the channel cell in keyboard mode.
  void jumpToChannel(LiveTvChannel channel) {
    if (_isLoading) {
      _pendingJumpChannel = channel;
      _pendingJumpProgram = null;
      return;
    }
    final index = _channelIndexFor(channel);
    if (index == null) return;

    // Focus state renders through _focusSnapshot listeners; _updateFocus
    // publishes it (a bare setState would leave the cells unchanged).
    _updateFocus(() {
      _focusZone = _GuideZone.grid;
      _gridChannelIndex = index;
      _gridColumn = 0;
      _focusedProgram = null;
    });
    if (InputModeTracker.isKeyboardMode(context)) _guideFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToChannel(index);
    });
  }

  /// Jump the guide to [program] on [channel] (from guide search), shifting
  /// the time window first when the airing isn't visible in the current one.
  Future<void> jumpToProgram(LiveTvChannel channel, LiveTvProgram program) async {
    if (_isLoading) {
      _pendingJumpChannel = channel;
      _pendingJumpProgram = program;
      return;
    }
    final index = _channelIndexFor(channel);
    if (index == null) return;

    _pauseFollowingForProgram(program);
    final begin = program.startTime;
    final end = program.endTime ?? begin;
    final intersectsWindow = begin != null && end != null && begin.isBefore(_gridEnd) && end.isAfter(_gridStart);
    if (begin != null && !intersectsWindow) {
      // Same window mechanics as the day/time-slot picker: anchor a fresh
      // 6-hour window one slot before the program and reload.
      var start = guideHalfHourStart(begin);
      start = start.subtract(const Duration(minutes: 30));
      setState(() {
        _gridStart = start;
        _gridEnd = start.add(const Duration(hours: 6));
        _followNow = false;
      });
      await _loadPrograms();
      if (!mounted) return;
    }

    // Re-resolve against the loaded list — the search sheet's program objects
    // come from its own fetch and never match _programs by identity.
    final target = _getProgramsForChannel(
      widget.channels[index],
    ).where((p) => p.beginsAt == program.beginsAt).firstOrNull;

    _updateFocus(() {
      _focusZone = _GuideZone.grid;
      _gridChannelIndex = index;
      _gridColumn = target != null ? 1 : 0;
      _focusedProgram = target;
    });
    if (InputModeTracker.isKeyboardMode(context)) _guideFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToChannel(index);
      if (target != null) _scrollToProgramTime(target);
    });
  }

  int? _channelIndexFor(LiveTvChannel channel) {
    final scopeKey = liveTvChannelScopeKey(channel);
    for (var i = 0; i < widget.channels.length; i++) {
      if (liveTvChannelScopeKey(widget.channels[i]) == scopeKey) return i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initTimeRange();
    _gridChannelIndex = _displayOrderChannelIndexes.firstOrNull ?? 0;
    _loadPrograms(scrollToStart: true);

    _gridHorizontalController.addListener(_syncGridToHeader);
    _headerHorizontalController.addListener(_syncHeaderToGrid);
  }

  // Not the gated data-refresh timer the other tabs run: the tick is a
  // per-minute UI ticker that advances the time indicator and follows the
  // current half-hour boundary when the user is not browsing another time.
  @override
  Duration get refreshInterval => const Duration(minutes: 1);

  @override
  void onRefreshTick() {
    _checkWindowDrift();
    // ignore: no-empty-block - setState triggers rebuild to update time indicator
    setStateIfMounted(() {});
  }

  @override
  void onRefreshPaused() {
    _resetGridSelectLongPressState();
    _followNowTimer?.cancel();
    _activePointers.clear();
    _lastGuideInteraction = null;
  }

  @override
  void onRefreshResumed(LiveTvRefreshResumeReason reason) {
    unawaited(_refreshScheduledRecordingKeys());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _catchUpIfStale();
    });
  }

  @override
  Future<void> tuneChannel(LiveTvChannel channel) {
    final index = _channelIndexFor(channel);
    if (index != null) _updateFocus(() => _gridChannelIndex = index);
    return super.tuneChannel(channel);
  }

  @override
  void didUpdateWidget(GuideTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldGroups = groupLiveTvGuideChannels(oldWidget.channels, favorites: oldWidget.favoriteChannels);
    final newGroups = _channelGroups;
    final previous = oldWidget.channels.elementAtOrNull(_gridChannelIndex);
    if (!identical(oldWidget.channels, widget.channels)) {
      _programsByChannelScope = _indexProgramsByChannel(_programs, widget.channels);
    }
    if (!_hasEnteredGrid) {
      _gridChannelIndex = _displayOrderChannelIndexes.firstOrNull ?? 0;
    } else if (previous != null && newGroups.isNotEmpty) {
      final key = liveTvChannelScopeKey(previous);
      final oldGroupIndex = oldGroups.indexWhere((group) => group.channels.any((c) => liveTvChannelScopeKey(c) == key));
      final oldGroup = oldGroups.elementAtOrNull(oldGroupIndex);
      final newGroup = newGroups.where((group) => group.key == oldGroup?.key).firstOrNull;
      LiveTvChannel? target;
      if (newGroup != null) {
        target = newGroup.channels.where((c) => liveTvChannelScopeKey(c) == key).firstOrNull;
        if (target == null && oldGroup != null) {
          // The channel left this group. Keep its row position, or the
          // previous row when it was last, instead of following it elsewhere.
          final position = oldGroup.channels.indexWhere((c) => liveTvChannelScopeKey(c) == key);
          target = newGroup.channels[position.clamp(0, newGroup.channels.length - 1)];
        }
      } else if (oldGroup != null) {
        for (final group in oldGroups.skip(oldGroupIndex + 1)) {
          target = newGroups
              .where((g) => g.key == group.key)
              .firstOrNull
              ?.channels
              .where((c) => liveTvChannelScopeKey(c) != key)
              .firstOrNull;
          if (target != null) break;
        }
        if (target == null) {
          for (final group in oldGroups.take(oldGroupIndex).toList().reversed) {
            target = newGroups
                .where((g) => g.key == group.key)
                .firstOrNull
                ?.channels
                .where((c) => liveTvChannelScopeKey(c) != key)
                .lastOrNull;
            if (target != null) break;
          }
        }
        target ??= newGroups.expand((g) => g.channels).where((c) => liveTvChannelScopeKey(c) != key).lastOrNull;
      }
      target ??= newGroups.first.channels.first;
      _gridChannelIndex = _channelIndexFor(target) ?? 0;
      if (liveTvChannelScopeKey(target) != key) {
        _resetGridSelectLongPressState();
        if (_gridColumn == 1) {
          final anchor = _focusedProgram?.beginsAt ?? _gridStart.millisecondsSinceEpoch ~/ 1000;
          final programs = _getProgramsForChannel(target);
          _focusedProgram =
              programs.where((p) => (p.beginsAt ?? 0) <= anchor && (p.endsAt ?? 0) > anchor).firstOrNull ??
              programs.firstOrNull;
        }
      }
    }
    if (_focusZone == _GuideZone.favorites && !_canReorderFavorites) {
      _focusZone = _GuideZone.grid;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _publishFocusSnapshot();
      if (_hasFocus && _focusZone == _GuideZone.grid) _scrollToChannel(_gridChannelIndex);
    });
  }

  @override
  void dispose() {
    _programLoadGeneration++;
    _followNowTimer?.cancel();
    _gridSelectController.dispose();
    _guideFocusNode.dispose();
    _gridVerticalController.dispose();
    _gridHorizontalController.removeListener(_syncGridToHeader);
    _headerHorizontalController.removeListener(_syncHeaderToGrid);
    _headerHorizontalController.dispose();
    _gridHorizontalController.dispose();
    _channelVerticalController.dispose();
    _focusSnapshot.dispose();
    _hoverPreview.dispose();
    super.dispose();
  }

  void _handleGuideFocusChange(bool hasFocus) {
    if (_hasFocus == hasFocus) return;
    if (!hasFocus) _resetGridSelectLongPressState();
    _hasFocus = hasFocus;
    _publishFocusSnapshot();
  }

  void _updateFocus(VoidCallback update) {
    _hoverPreview.value = null;
    _resetGridSelectLongPressState();
    update();
    if (_focusZone == _GuideZone.grid) _hasEnteredGrid = true;
    _publishFocusSnapshot();
  }

  void _publishFocusSnapshot() {
    _focusSnapshot.value = (
      hasFocus: _hasFocus,
      zone: _focusZone,
      timeNavIndex: _timeNavIndex,
      channelIndex: _gridChannelIndex,
      gridColumn: _gridColumn,
      program: _focusedProgram,
    );
  }

  void _resetGridSelectLongPressState() => _gridSelectController.reset();

  void _syncGridToHeader() {
    if (_syncingScroll) return;
    _syncingScroll = true;
    if (_headerHorizontalController.hasClients) {
      _headerHorizontalController.jumpTo(_gridHorizontalController.offset);
    }
    _syncingScroll = false;
  }

  void _syncHeaderToGrid() {
    if (_syncingScroll) return;
    _syncingScroll = true;
    if (_gridHorizontalController.hasClients) {
      _gridHorizontalController.jumpTo(_headerHorizontalController.offset);
    }
    _syncingScroll = false;
  }

  void _initTimeRange() {
    _gridStart = guideHalfHourStart(clock.now());
    _gridEnd = _gridStart.add(const Duration(hours: 6));
    _followNow = true;
  }

  void _shiftTimeRange(int hours) {
    setState(() {
      _gridStart = _gridStart.add(Duration(hours: hours));
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _followNow = false;
    });
    _loadPrograms();
  }

  void _jumpToNow() {
    _followNowTimer?.cancel();
    _initTimeRange();
    _loadPrograms(scrollToStart: true, focusCurrentProgram: true);
  }

  void _noteGuideInteraction() => _lastGuideInteraction = clock.now();

  void _pauseFollowingForProgram(LiveTvProgram program) {
    final now = clock.now().millisecondsSinceEpoch ~/ 1000;
    if (program.beginsAt == null || program.endsAt == null || program.beginsAt! > now || program.endsAt! <= now) {
      _followNow = false;
    }
  }

  bool _handleUserScroll(UserScrollNotification notification) {
    if (notification.direction != ScrollDirection.idle) {
      _noteGuideInteraction();
      if (notification.metrics.axis == Axis.horizontal) _followNow = false;
    }
    return false;
  }

  /// Arm the next boundary, backed by the minute ticker, and retry after
  /// input settles. Do not move a card under a held SELECT, pointer, or popup.
  void _checkWindowDrift({bool returning = false}) {
    if (!mounted || !isRefreshActive || _isLoading || !_followNow) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final now = clock.now();
    if (guideHalfHourStart(now).isAtSameMomentAs(_gridStart)) {
      _followNowTimer?.cancel();
      _followNowTimer = Timer(_gridStart.add(const Duration(minutes: 30)).difference(now), _checkWindowDrift);
      return;
    }
    final recentInput =
        _lastGuideInteraction != null && clock.now().difference(_lastGuideInteraction!) < _followNowIdleDelay;
    final scrolling = _gridVerticalController.hasClients && _gridVerticalController.position.isScrollingNotifier.value;
    if (_activePointers.isNotEmpty ||
        HardwareKeyboard.instance.physicalKeysPressed.isNotEmpty ||
        scrolling ||
        (!returning && recentInput)) {
      _followNowTimer?.cancel();
      _followNowTimer = Timer(_followNowIdleDelay, _checkWindowDrift);
      return;
    }
    _jumpToNow();
  }

  /// Playback/tab/app returns catch up even after a short absence. Explicit
  /// history/future browsing remains parked until the user chooses Now.
  void _catchUpIfStale() => _checkWindowDrift(returning: true);

  bool _isCurrentProgramLoad(int generation) => mounted && generation == _programLoadGeneration;

  Future<void> _loadPrograms({bool scrollToStart = false, bool focusCurrentProgram = false}) async {
    if (!mounted) return;
    final loadGeneration = ++_programLoadGeneration;
    final requestGridStart = _gridStart;
    final requestGridEnd = _gridEnd;
    final startEpoch = requestGridStart.millisecondsSinceEpoch ~/ 1000;
    final endEpoch = requestGridEnd.millisecondsSinceEpoch ~/ 1000;
    final from = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000, isUtc: true);
    final to = DateTime.fromMillisecondsSinceEpoch(endEpoch * 1000, isUtc: true);
    setState(() => _isLoading = true);

    try {
      final allPrograms = <LiveTvProgram>[];
      final scheduledRecordingKeys = <String>{};
      final multiServer = context.read<MultiServerProvider>();

      await forEachLiveTvServer(
        multiServer,
        resolveClient: multiServer.getClientForServer,
        isCurrent: () => _isCurrentProgramLoad(loadGeneration),
        body: (client, serverInfo) async {
          final programs = await client.liveTv.fetchSchedule(from: from, to: to);
          if (!_isCurrentProgramLoad(loadGeneration)) return;
          allPrograms.addAll(programs);
          await _addScheduledRecordingKeysForServer(
            client: client,
            serverId: ServerId(serverInfo.serverId),
            keys: scheduledRecordingKeys,
            isCurrent: () => _isCurrentProgramLoad(loadGeneration),
          );
        },
        onError: (client, serverInfo, error, stackTrace) {
          if (!_isCurrentProgramLoad(loadGeneration)) return;
          appLogger.e('Failed to load programs from server ${serverInfo.serverId}', error: error);
        },
      );

      if (!_isCurrentProgramLoad(loadGeneration)) return;
      final shouldFocus = _pendingFocus;
      final programsByChannelScope = _indexProgramsByChannel(allPrograms, widget.channels);
      final pendingJumpChannel = _pendingJumpChannel;
      final pendingJumpProgram = _pendingJumpProgram;
      _pendingJumpChannel = null;
      _pendingJumpProgram = null;

      setState(() {
        _programs = allPrograms;
        _programsByChannelScope = programsByChannelScope;
        _scheduledRecordingKeys = scheduledRecordingKeys;
        _recordingOverrides = const {};
        _isLoading = false;
        _hasLoadedOnce = true;
        // Focus tracking compares by identity, so a reload orphans the
        // focused program — re-resolve it against the fresh list.
        if (_focusZone == _GuideZone.grid && _gridColumn == 1 && _focusedProgram != null) {
          final focused = _focusedProgram;
          if (!_programs.any((p) => identical(p, focused))) {
            final channel = widget.channels.elementAtOrNull(_gridChannelIndex);
            if (focusCurrentProgram && _followNow) {
              _focusedProgram = _findCurrentProgram(_gridChannelIndex);
            } else if (channel != null) {
              final airing = guideAiringIdentity(channel, focused!);
              _focusedProgram =
                  _getProgramsForChannel(channel).where((p) => guideAiringIdentity(channel, p) == airing).firstOrNull ??
                  _findCurrentProgram(_gridChannelIndex);
            } else {
              _focusedProgram = null;
            }
          }
        }
      });
      _publishFocusSnapshot();

      if (pendingJumpChannel != null) {
        // A stashed search jump wins over the default live-line anchoring and
        // over any focus request queued during the load.
        _pendingFocus = false;
        if (pendingJumpProgram != null) {
          unawaited(jumpToProgram(pendingJumpChannel, pendingJumpProgram));
        } else {
          jumpToChannel(pendingJumpChannel);
        }
        return;
      }

      if (scrollToStart && _followNow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isCurrentProgramLoad(loadGeneration) && _gridHorizontalController.hasClients) {
            _gridHorizontalController.jumpTo(0);
          }
        });
      } else if (_followNow) {
        _scrollToNow(loadGeneration: loadGeneration);
      }
      // A load can finish after a boundary or after returning from playback.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isCurrentProgramLoad(loadGeneration)) _checkWindowDrift();
      });

      if (shouldFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isCurrentProgramLoad(loadGeneration)) focusContent();
        });
      }
    } catch (e) {
      if (!_isCurrentProgramLoad(loadGeneration)) return;
      appLogger.e('Failed to load guide programs', error: e);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshScheduledRecordingKeys() async {
    if (!mounted) return;
    final multiServer = context.read<MultiServerProvider>();
    final scheduledRecordingKeys = <String>{};

    await forEachLiveTvServer(
      multiServer,
      resolveClient: multiServer.getClientForServer,
      body: (client, serverInfo) => _addScheduledRecordingKeysForServer(
        client: client,
        serverId: ServerId(serverInfo.serverId),
        keys: scheduledRecordingKeys,
      ),
    );

    if (!mounted) return;
    setState(() => _scheduledRecordingKeys = scheduledRecordingKeys);
  }

  Future<void> _addScheduledRecordingKeysForServer({
    required MediaServerClient client,
    required ServerId serverId,
    required Set<String> keys,
    bool Function()? isCurrent,
  }) async {
    final dvr = client.liveTvDvr;
    if (dvr == null) return;
    try {
      final grabs = await dvr.fetchScheduledRecordings();
      if (isCurrent?.call() == false) return;
      for (final grab in grabs) {
        _addRecordingKeysForGrab(grab, serverId: ServerId(serverId), keys: keys);
      }
    } catch (e) {
      if (isCurrent?.call() == false) return;
      appLogger.d('Failed to load scheduled recordings for $serverId', error: e);
    }

    try {
      final rules = await dvr.fetchRecordingRules(includeGrabs: true, includeStorage: false);
      if (isCurrent?.call() == false) return;
      for (final rule in rules) {
        for (final grab in rule.grabOperations) {
          _addRecordingKeysForGrab(grab, serverId: ServerId(serverId), keys: keys);
        }
      }
    } catch (e) {
      if (isCurrent?.call() == false) return;
      appLogger.d('Failed to load active recording grabs for $serverId', error: e);
    }
  }

  void _addRecordingKeysForGrab(MediaGrabOperation grab, {required ServerId serverId, required Set<String> keys}) {
    if (!_isActiveScheduledGrab(grab)) return;
    final program = grab.program;
    if (program == null) return;
    keys.addAll(_recordingKeysForProgram(program, fallbackServerId: serverId));
  }

  bool _isActiveScheduledGrab(MediaGrabOperation grab) {
    final status = grab.status?.trim().toLowerCase();
    return status == null || status.isEmpty || status == 'scheduled' || status == 'grabbing' || status == 'recording';
  }

  bool _isRecordingScheduled(LiveTvProgram program) {
    final keys = _recordingKeysForProgram(program);
    for (final key in keys) {
      final override = _recordingOverrides[key];
      if (override != null) return override;
    }
    // The grid response tags subscribed airings itself (subscriptionID /
    // grandparentSubscriptionID) — the signal the official client renders
    // its record badges from. Grab matching below stays as the secondary
    // signal for airings the server did not tag.
    if (program.recordingRuleKey != null) return true;
    return keys.any(_scheduledRecordingKeys.contains);
  }

  void _handleRecordingStateChanged(LiveTvProgram program, bool isScheduled) {
    final keys = _recordingKeysForProgram(program);
    if (keys.isNotEmpty) {
      setState(() {
        _recordingOverrides = {..._recordingOverrides, for (final key in keys) key: isScheduled};
      });
    }
    unawaited(_refreshScheduledRecordingKeys());
  }

  Set<String> _recordingKeysForProgram(LiveTvProgram program, {String? fallbackServerId}) {
    final serverId = liveTvNonEmpty(program.serverId) ?? liveTvNonEmpty(fallbackServerId);
    if (serverId == null) return const <String>{};

    final keys = <String>{};
    void addMediaId(String? value) {
      final normalized = liveTvNonEmpty(value);
      if (normalized != null) keys.add(_recordingKey(ServerId(serverId), 'media', normalized));
    }

    addMediaId(program.ratingKey);
    addMediaId(program.guid);
    addMediaId(program.key);

    final channelIdentifier = liveTvNonEmpty(program.channelIdentifier);
    final beginsAt = program.beginsAt;
    if (channelIdentifier != null && beginsAt != null) {
      keys.add(_recordingKey(ServerId(serverId), 'slot', '$channelIdentifier|$beginsAt|${program.endsAt ?? ''}'));
    }

    return keys;
  }

  String _recordingKey(ServerId serverId, String type, String value) => '$serverId\u0000$type\u0000$value';

  List<LiveTvChannelGroup> get _channelGroups =>
      groupLiveTvGuideChannels(widget.channels, favorites: widget.favoriteChannels);

  bool get _canReorderFavorites => widget.onReorderFavorites != null && widget.favoriteChannels.length > 1;

  List<_GuideRow> get _guideRows {
    final groups = _channelGroups;
    final indexes = {for (var i = 0; i < widget.channels.length; i++) liveTvChannelScopeKey(widget.channels[i]): i};
    return [
      for (final group in groups) ...[
        if (groups.length > 1 || group.key == liveTvFavoritesGroupKey)
          _GuideSourceHeaderRow(label: group.label, favorites: group.key == liveTvFavoritesGroupKey),
        for (final channel in group.channels)
          _GuideChannelRow(channel: channel, channelIndex: indexes[liveTvChannelScopeKey(channel)]!),
      ],
    ];
  }

  /// Flat [GuideTab.channels] indexes in displayed row order. Differs from
  /// ascending index order when multiple source groups exist: the flat list is
  /// number-sorted across sources, while rows are grouped by source.
  List<int> get _displayOrderChannelIndexes => [
    for (final row in _guideRows)
      if (row is _GuideChannelRow) row.channelIndex,
  ];

  double _guideRowHeight(_GuideRow row) {
    return switch (row) {
      _GuideSourceHeaderRow() => _sourceHeaderRowHeight,
      _GuideChannelRow() => _rowHeight,
    };
  }

  double _guideContentHeight(List<_GuideRow> rows) {
    var height = 0.0;
    for (final row in rows) {
      height += _guideRowHeight(row);
    }
    return height;
  }

  double _rowTopForChannelIndex(int channelIndex) {
    var top = 0.0;
    for (final row in _guideRows) {
      if (row is _GuideChannelRow && row.channelIndex == channelIndex) return top;
      top += _guideRowHeight(row);
    }
    return channelIndex * _rowHeight;
  }

  void _scrollToNow({int? loadGeneration}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (loadGeneration != null && !_isCurrentProgramLoad(loadGeneration))) return;
      final now = clock.now();
      final minutesSinceStart = now.difference(_gridStart).inMinutes;
      final offset = (minutesSinceStart / _minutesPerSlot) * _slotWidth;
      if (_gridHorizontalController.hasClients) {
        _gridHorizontalController.jumpTo(
          (offset - MediaQuery.sizeOf(context).width / 3).clamp(0, _gridHorizontalController.position.maxScrollExtent),
        );
      }
    });
  }

  Map<String, List<LiveTvProgram>> _indexProgramsByChannel(List<LiveTvProgram> programs, List<LiveTvChannel> channels) {
    final programsByIdentifier = <String, List<LiveTvProgram>>{};
    for (final program in programs) {
      final identifier = program.channelIdentifier?.trim();
      if (identifier == null || identifier.isEmpty) continue;
      (programsByIdentifier[identifier] ??= []).add(program);
    }

    final indexed = <String, List<LiveTvProgram>>{};
    for (final channel in channels) {
      final candidates = <LiveTvProgram>{};
      candidates.addAll(programsByIdentifier[channel.key] ?? const []);
      final identifier = channel.identifier;
      if (identifier != null && identifier != channel.key) {
        candidates.addAll(programsByIdentifier[identifier] ?? const []);
      }
      final matching = candidates.where((program) => liveTvProgramMatchesChannel(program, channel)).toList()
        ..sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
      indexed[liveTvChannelScopeKey(channel)] = matching;
    }
    return indexed;
  }

  List<LiveTvProgram> _getProgramsForChannel(LiveTvChannel channel) {
    return _programsByChannelScope[liveTvChannelScopeKey(channel)] ?? const [];
  }

  double _totalGridWidth() {
    final totalMinutes = _gridEnd.difference(_gridStart).inMinutes;
    return (totalMinutes / _minutesPerSlot) * _slotWidth;
  }

  void _activateProgram(LiveTvChannel channel, LiveTvProgram program) {
    _pauseFollowingForProgram(program);
    if (PlatformDetector.isTV() && program.isCurrentlyAiring) {
      tuneChannel(channel);
      return;
    }

    _showProgramDetails(channel, program);
  }

  ({LiveTvChannel channel, LiveTvProgram program})? _focusedProgramTarget() {
    if (_focusZone != _GuideZone.grid || _gridColumn != 1) return null;
    final program = _focusedProgram;
    if (program == null) return null;
    if (_gridChannelIndex < 0 || _gridChannelIndex >= widget.channels.length) return null;

    return (channel: widget.channels[_gridChannelIndex], program: program);
  }

  KeyEventResult _handleFocusedGridSelectKey(KeyEvent event) {
    if (_focusZone == _GuideZone.grid && _gridColumn == 0) {
      final channel = widget.channels.elementAtOrNull(_gridChannelIndex);
      if (channel == null) return KeyEventResult.ignored;
      final identity = liveTvChannelScopeKey(channel);
      bool isOwnerActive() {
        final focused = widget.channels.elementAtOrNull(_gridChannelIndex);
        return mounted &&
            _hasFocus &&
            _focusZone == _GuideZone.grid &&
            _gridColumn == 0 &&
            focused != null &&
            liveTvChannelScopeKey(focused) == identity;
      }

      return _gridSelectController.handleKeyEvent(
        event,
        isOwnerActive: isOwnerActive,
        onShortPress: () {
          if (isOwnerActive()) tuneChannel(channel);
        },
        onLongPress: () {
          _resetGridSelectLongPressState();
          widget.onToggleFavorite?.call(channel);
        },
      );
    }

    final target = _focusedProgramTarget();
    if (target == null) return KeyEventResult.ignored;

    final ownerChannelIndex = _gridChannelIndex;
    final targetIdentity = guideAiringIdentity(target.channel, target.program);
    return _gridSelectController.handleKeyEvent(
      event,
      isOwnerActive: () {
        if (!mounted || _focusZone != _GuideZone.grid || _gridColumn != 1 || _gridChannelIndex != ownerChannelIndex) {
          return false;
        }

        final activeTarget = _focusedProgramTarget();
        return activeTarget != null &&
            guideAiringIdentity(activeTarget.channel, activeTarget.program) == targetIdentity;
      },
      onShortPress: () => _activateProgram(target.channel, target.program),
      onLongPress: () {
        _gridSelectController.reset();
        _showProgramDetails(target.channel, target.program);
      },
    );
  }

  KeyEventResult _handleFocusedProgramContextMenuKey(KeyEvent event) {
    if (!event.logicalKey.isContextMenuKey || !event.isActionable) return KeyEventResult.ignored;
    final target = _focusedProgramTarget();
    if (target == null) return KeyEventResult.ignored;

    _resetGridSelectLongPressState();
    _showProgramDetails(target.channel, target.program);
    return KeyEventResult.handled;
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    _noteGuideInteraction();

    if (SelectKeyUpSuppressor.consumeIfSuppressed(event)) {
      if (event is KeyUpEvent && key.isSelectKey) {
        _resetGridSelectLongPressState();
      }
      return KeyEventResult.handled;
    }

    // Back key
    if (key.isBackKey) {
      if (BackKeyUpSuppressor.consumeIfSuppressed(event)) {
        return KeyEventResult.handled;
      }
      if (_focusZone != _GuideZone.timeNav) {
        if (event is KeyUpEvent) {
          _updateFocus(() {
            _focusZone = _GuideZone.timeNav;
            _timeNavIndex = 1;
          });
        }
        return KeyEventResult.handled;
      }
      return handleBackKeyAction(event, () => widget.onBack?.call());
    }

    if (PlatformDetector.isTV()) {
      final selectResult = _handleFocusedGridSelectKey(event);
      if (selectResult != KeyEventResult.ignored) return selectResult;
    }

    final contextMenuResult = _handleFocusedProgramContextMenuKey(event);
    if (contextMenuResult != KeyEventResult.ignored) return contextMenuResult;

    if (!event.isActionable) return KeyEventResult.ignored;

    return switch (_focusZone) {
      _GuideZone.timeNav => _handleTimeNavKey(key),
      _GuideZone.favorites => _handleFavoritesHeaderKey(key),
      _GuideZone.grid => _handleGridKey(key),
    };
  }

  KeyEventResult _handleTimeNavKey(LogicalKeyboardKey key) {
    if (key.isLeftKey) {
      if (_timeNavIndex > 0) {
        _updateFocus(() => _timeNavIndex--);
      } else {
        widget.onBack?.call();
      }
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      if (_timeNavIndex < 2) _updateFocus(() => _timeNavIndex++);
      return KeyEventResult.handled;
    }
    if (key.isDownKey) {
      if (widget.channels.isNotEmpty) {
        _updateFocus(() {
          _focusZone = _GuideZone.grid;
          _gridColumn = 0;
          _focusedProgram = null;
        });
        _scrollToChannel(_gridChannelIndex);
      }
      return KeyEventResult.handled;
    }
    if (key.isUpKey) {
      widget.onNavigateUp?.call();
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      switch (_timeNavIndex) {
        case 0:
          _shiftTimeRange(-2);
        case 1:
          // The menu takes focus; suppress the in-flight SELECT key-up so the
          // press that opened it cannot also activate the first menu item.
          SelectKeyUpSuppressor.suppressSelectUntilKeyUp();
          _showDayPicker();
        case 2:
          _shiftTimeRange(2);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _reorderFavorites() {
    SelectKeyUpSuppressor.suppressSelectUntilKeyUp();
    widget.onReorderFavorites?.call();
  }

  KeyEventResult _handleFavoritesHeaderKey(LogicalKeyboardKey key) {
    if (key.isSelectKey) {
      _reorderFavorites();
    } else if (key.isDownKey) {
      _updateFocus(() {
        _focusZone = _GuideZone.grid;
        _gridColumn = 0;
        _gridChannelIndex = _displayOrderChannelIndexes.first;
      });
      _scrollToChannel(_gridChannelIndex);
    } else if (key.isUpKey) {
      _updateFocus(() {
        _focusZone = _GuideZone.timeNav;
        _timeNavIndex = 1;
      });
    } else if (key.isLeftKey) {
      widget.onBack?.call();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _handleGridKey(LogicalKeyboardKey key) {
    if (key.isUpKey || key.isDownKey) {
      // Move through rows in displayed (source-grouped) order. Stepping the
      // flat channel index would interleave sources whose channel numbers
      // overlap and could dead-end before the last displayed row.
      final order = _displayOrderChannelIndexes;
      final position = order.indexOf(_gridChannelIndex);
      if (key.isUpKey && position <= 0) {
        _updateFocus(() {
          _focusZone = _canReorderFavorites ? _GuideZone.favorites : _GuideZone.timeNav;
          _timeNavIndex = 1;
        });
        if (_canReorderFavorites && _gridVerticalController.hasClients) _gridVerticalController.jumpTo(0);
      } else if (key.isUpKey || (position != -1 && position < order.length - 1)) {
        _updateFocus(() {
          _gridChannelIndex = order[key.isUpKey ? position - 1 : position + 1];
          if (_gridColumn == 1) _focusedProgram = _findCurrentProgram(_gridChannelIndex);
        });
        _scrollToChannel(_gridChannelIndex);
      }
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      if (_gridColumn == 0) {
        final program = _findCurrentProgram(_gridChannelIndex);
        if (program != null) {
          _updateFocus(() {
            _gridColumn = 1;
            _focusedProgram = program;
          });
          _scrollToProgramTime(program);
        }
      } else {
        // Already in program column — move to next program
        _navigateToAdjacentProgram(_gridChannelIndex, forward: true);
      }
      return KeyEventResult.handled;
    }
    if (key.isLeftKey) {
      if (_gridColumn == 1) {
        // Try moving to previous program; if at first program, go back to channel column
        if (!_navigateToAdjacentProgram(_gridChannelIndex, forward: false)) {
          _updateFocus(() {
            _gridColumn = 0;
            _focusedProgram = null;
          });
        }
      } else {
        widget.onBack?.call();
      }
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      if (_gridChannelIndex >= 0 && _gridChannelIndex < widget.channels.length) {
        final channel = widget.channels[_gridChannelIndex];
        if (_gridColumn == 0) {
          tuneChannel(channel);
        } else if (_focusedProgram != null) {
          _activateProgram(channel, _focusedProgram!);
        }
      }
      return KeyEventResult.handled;
    }
    // 'F' key toggles favorite on focused channel
    if (key == LogicalKeyboardKey.keyF && _gridColumn == 0) {
      if (_gridChannelIndex >= 0 && _gridChannelIndex < widget.channels.length) {
        widget.onToggleFavorite?.call(widget.channels[_gridChannelIndex]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  LiveTvProgram? _findCurrentProgram(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= widget.channels.length) return null;
    final channel = widget.channels[channelIndex];
    final programs = _getProgramsForChannel(channel);
    final now = clock.now().millisecondsSinceEpoch ~/ 1000;

    // Currently airing
    for (final p in programs) {
      if ((p.beginsAt ?? 0) <= now && (p.endsAt ?? 0) > now) return p;
    }
    // First future program
    for (final p in programs) {
      if ((p.endsAt ?? 0) > now) return p;
    }
    return programs.firstOrNull;
  }

  /// Navigate to the next or previous program on the same channel.
  /// Returns true if navigation succeeded, false if at the boundary.
  bool _navigateToAdjacentProgram(int channelIndex, {required bool forward}) {
    if (channelIndex < 0 || channelIndex >= widget.channels.length) return false;
    final channel = widget.channels[channelIndex];
    final programs = _getProgramsForChannel(channel);
    if (programs.isEmpty || _focusedProgram == null) return false;

    final currentIndex = programs.indexWhere((p) => identical(p, _focusedProgram));
    if (currentIndex < 0) return false;

    final nextIndex = forward ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex < 0 || nextIndex >= programs.length) return false;

    final nextProgram = programs[nextIndex];
    _pauseFollowingForProgram(nextProgram);
    _updateFocus(() => _focusedProgram = nextProgram);
    _scrollToProgramTime(nextProgram);
    return true;
  }

  void _scrollToChannel(int index) {
    if (!_gridVerticalController.hasClients) return;
    final targetTop = _rowTopForChannelIndex(index);
    final targetBottom = targetTop + _rowHeight;
    final viewportTop = _gridVerticalController.offset;
    final viewportBottom = viewportTop + _gridVerticalController.position.viewportDimension;

    double? newOffset;
    if (targetTop < viewportTop) {
      newOffset = targetTop;
    } else if (targetBottom > viewportBottom) {
      newOffset = targetBottom - _gridVerticalController.position.viewportDimension;
    }

    if (newOffset != null) {
      final clamped = newOffset.clamp(0.0, _gridVerticalController.position.maxScrollExtent);
      _gridVerticalController.animateTo(clamped, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      if (_channelVerticalController.hasClients) {
        _channelVerticalController.animateTo(
          clamped.clamp(0.0, _channelVerticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void _scrollToProgramTime(LiveTvProgram? program) {
    if (program == null || !_gridHorizontalController.hasClients) return;

    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final gridEndEpoch = _gridEnd.millisecondsSinceEpoch ~/ 1000;
    final progStart = (program.beginsAt ?? gridStartEpoch).clamp(gridStartEpoch, gridEndEpoch);
    final startOffset = progStart - gridStartEpoch;
    final left = (startOffset / (_minutesPerSlot * 60)) * _slotWidth;

    final viewportWidth = _gridHorizontalController.position.viewportDimension;
    final currentOffset = _gridHorizontalController.offset;

    if (left < currentOffset || left > currentOffset + viewportWidth - 100) {
      final maxScroll = _gridHorizontalController.position.maxScrollExtent;
      _gridHorizontalController.jumpTo((left - 50).clamp(0.0, maxScroll));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Full-screen spinner only before the first window has loaded. In-session
    // window reloads keep the grid mounted (so the day/time pickers and the
    // guide Focus stay alive for D-pad navigation) and show a lightweight
    // overlay instead — stale programs stay tappable while it settles.
    if (_isLoading && !_hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      fit: StackFit.passthrough,
      children: [
        Focus(
          focusNode: _guideFocusNode,
          onFocusChange: _handleGuideFocusChange,
          onKeyEvent: _handleKeyEvent,
          child: Listener(
            onPointerDown: (event) {
              _activePointers.add(event.pointer);
              _noteGuideInteraction();
            },
            onPointerUp: (event) {
              _activePointers.remove(event.pointer);
              _noteGuideInteraction();
            },
            onPointerCancel: (event) => _activePointers.remove(event.pointer),
            child: NotificationListener<UserScrollNotification>(
              onNotification: _handleUserScroll,
              child: _buildGuideGrid(theme),
            ),
          ),
        ),
        if (_isLoading)
          const Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildGuideGrid(ThemeData theme) {
    final rows = _guideRows;
    final isTv = PlatformDetector.isTV();
    final grid = ListenableBuilder(
      key: const ValueKey('guide-timeline-grid'),
      listenable: _gridHorizontalController,
      builder: (context, child) {
        return Stack(children: [child!, _buildNowIndicatorOverlay(theme)]);
      },
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(width: _channelColumnWidth, height: _timeHeaderHeight),
              Expanded(
                child: SingleChildScrollView(
                  controller: _headerHorizontalController,
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: SizedBox(width: _totalGridWidth(), height: _timeHeaderHeight, child: _buildTimeHeader(theme)),
                ),
              ),
            ],
          ),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: _channelColumnWidth,
                  child: CustomScrollView(
                    controller: _channelVerticalController,
                    physics: const NeverScrollableScrollPhysics(),
                    slivers: [
                      SliverVariedExtentList.builder(
                        itemCount: rows.length,
                        itemExtentBuilder: (index, _) => _guideRowHeight(rows[index]),
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          return switch (row) {
                            _GuideSourceHeaderRow(:final label) => _buildSourceHeaderCell(label, theme),
                            _GuideChannelRow(:final channel, :final channelIndex) => _buildChannelCell(
                              channel,
                              theme,
                              index: channelIndex,
                            ),
                          };
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollUpdateNotification && notification.metrics.axis == Axis.vertical) {
                        if (_channelVerticalController.hasClients) {
                          _channelVerticalController.jumpTo(notification.metrics.pixels);
                        }
                      }
                      return false;
                    },
                    child: SingleChildScrollView(
                      controller: _gridHorizontalController,
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: SizedBox(
                        width: _totalGridWidth(),
                        child: CustomScrollView(
                          controller: _gridVerticalController,
                          slivers: [
                            SliverVariedExtentList.builder(
                              itemCount: rows.length,
                              itemExtentBuilder: (index, _) => _guideRowHeight(rows[index]),
                              itemBuilder: (context, index) {
                                final row = rows[index];
                                return switch (row) {
                                  _GuideSourceHeaderRow(:final label, :final favorites) => _buildSourceHeaderGridRow(
                                    label,
                                    theme,
                                    favorites: favorites,
                                  ),
                                  _GuideChannelRow(:final channel, :final channelIndex) => _buildProgramRow(
                                    channel,
                                    _getProgramsForChannel(channel),
                                    theme,
                                    channelIndex: channelIndex,
                                  ),
                                };
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!isTv) {
      _rowHeight = 64;
      return Column(
        children: [
          _buildTimeNavigation(theme),
          Expanded(child: grid),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        var headers = 0;
        var channels = 0;
        for (final row in rows) {
          if (channels == _tvVisibleChannelRows) break;
          if (row is _GuideSourceHeaderRow) {
            headers++;
          } else {
            channels++;
          }
        }
        // Reserve room for six channel rows, including the source headings
        // above them. Smaller TV viewports use a compact row, not fewer rows.
        _rowHeight = ((constraints.maxHeight - 240 - headers * _sourceHeaderRowHeight) / _tvVisibleChannelRows).clamp(
          48.0,
          72.0,
        );
        return Column(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([_focusSnapshot, _hoverPreview]),
                builder: (context, _) {
                  final focus = _focusSnapshot.value;
                  final hover = _hoverPreview.value;
                  final channel = hover?.channel ?? widget.channels.elementAtOrNull(focus.channelIndex);
                  final programs = channel == null ? const <LiveTvProgram>[] : _getProgramsForChannel(channel);
                  final epoch = clock.now().millisecondsSinceEpoch ~/ 1000;
                  final program =
                      (hover == null ? focus.program : hover.program) ??
                      programs
                          .where((p) => (p.beginsAt ?? epoch + 1) <= epoch && (p.endsAt ?? 0) > epoch)
                          .firstOrNull ??
                      programs.firstOrNull;
                  return TvGuideProgramInfo(channel: channel, program: program);
                },
              ),
            ),
            _buildTimeNavigation(theme),
            SizedBox(
              height: _timeHeaderHeight + _rowHeight * _tvVisibleChannelRows + headers * _sourceHeaderRowHeight,
              child: grid,
            ),
          ],
        );
      },
    );
  }

  Widget _buildNowIndicatorOverlay(ThemeData _) {
    final now = clock.now();
    if (now.isBefore(_gridStart) || now.isAfter(_gridEnd)) {
      return const SizedBox.shrink();
    }
    final minutesSinceStart = now.difference(_gridStart).inMinutes.toDouble();
    final nowOffset = (minutesSinceStart / _minutesPerSlot) * _slotWidth;
    final scrollOffset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
    final left = _channelColumnWidth + nowOffset - scrollOffset;

    // Hide when scrolled behind the channel column
    if (left < _channelColumnWidth) return const SizedBox.shrink();

    final gridHeight = _timeHeaderHeight + _guideContentHeight(_guideRows);

    return Positioned(
      left: left,
      top: 0,
      height: gridHeight,
      child: IgnorePointer(child: Container(width: 2, color: Colors.red)),
    );
  }

  String _dayLabel(DateTime day) {
    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);

    if (target == today) return t.liveTv.today;
    if (target == DateTime(now.year, now.month, now.day + 1)) return t.liveTv.tomorrow;

    return DateFormat('EEEE', LocaleSettings.currentLocale.intlLocaleName).format(target);
  }

  List<(String, int)> get _timeSlots => [
    (t.liveTv.midnight, 0),
    (t.liveTv.overnight, 2),
    (t.liveTv.morning, 6),
    (t.liveTv.daytime, 12),
    (t.liveTv.evening, 18),
    (t.liveTv.lateNight, 22),
  ];

  Rect? _menuAnchorRect() {
    final renderBox = _dayPickerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;

    final buttonPos = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;
    return Rect.fromLTWH(buttonPos.dx, buttonPos.dy, buttonSize.width, buttonSize.height);
  }

  Future<void> _showDayPicker() async {
    final anchorRect = _menuAnchorRect();
    if (anchorRect == null) return;

    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final gridDay = DateTime(_gridStart.year, _gridStart.month, _gridStart.day);

    final days = <DateTime>[];
    for (var i = 0; i < 8; i++) {
      days.add(DateTime(today.year, today.month, today.day + i));
    }

    final value = await showAppMenu<Object>(
      context,
      anchorRect: anchorRect,
      focusFirstItem: InputModeTracker.isKeyboardMode(context),
      entries: [
        AppMenuItem<Object>(value: 'now', label: t.liveTv.now),
        ...days.map((day) {
          final isSelected = day == gridDay;
          final label = _dayLabel(day);
          return AppMenuItem<Object>(value: day, label: label, selected: isSelected);
        }),
      ],
    );
    if (!mounted) return;
    if (value == null) {
      _guideFocusNode.requestFocus();
      return;
    }
    if (value is String && value == 'now') {
      _jumpToNow();
      _guideFocusNode.requestFocus();
    } else if (value is DateTime) {
      // Apply the picked day right away; the slot menu that follows only
      // refines it (dismissing it keeps this window).
      _applyDay(value);
      await _showTimeSlotPicker(value);
    }
  }

  /// Re-anchors the 6h window onto [day] keeping the current window's
  /// time-of-day. Picking 'Now' instead re-anchors live via [_jumpToNow].
  /// #1297: a deliberately picked day is never yanked back by the drift
  /// checker — [_followNow] stays false for an explicitly picked window.
  void _applyDay(DateTime day) {
    final hour = _gridStart.hour;
    final minute = _gridStart.minute;
    setState(() {
      _gridStart = DateTime(day.year, day.month, day.day, hour, minute);
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _followNow = false;
    });
    unawaited(_loadPrograms());
  }

  Future<void> _showTimeSlotPicker(DateTime day) async {
    final anchorRect = _menuAnchorRect();
    if (anchorRect == null) return;

    final label = _dayLabel(day).toUpperCase();

    final value = await showAppMenu<int>(
      context,
      anchorRect: anchorRect,
      focusFirstItem: InputModeTracker.isKeyboardMode(context),
      entries: [
        AppMenuItem<int>(
          value: -1,
          icon: Symbols.chevron_left_rounded,
          child: Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: .bold)),
        ),
        const AppMenuDivider<int>(),
        ..._timeSlots.map((slot) {
          return AppMenuItem<int>(value: slot.$2, label: slot.$1);
        }),
      ],
    );
    if (!mounted) return;
    if (value == null) {
      _guideFocusNode.requestFocus();
      return;
    }
    if (value == -1) {
      await _showDayPicker();
      return;
    }
    setState(() {
      _gridStart = DateTime(day.year, day.month, day.day, value);
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _followNow = false;
    });
    unawaited(_loadPrograms());
    _guideFocusNode.requestFocus();
  }

  Widget _timeNavFocusWrap({required Widget child, required int index}) {
    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) => focus.hasFocus && focus.zone == _GuideZone.timeNav && focus.timeNavIndex == index,
      builder: (context, isFocused) {
        if (!isFocused) return child;
        return Container(
          decoration: FocusTheme.textFillFocusDecoration(context, isFocused: true, borderRadius: MonoTokens.radiusFull),
          child: child,
        );
      },
    );
  }

  Widget _buildTimeNavigation(ThemeData theme) {
    final timeLabel = formatClockTime(_gridStart, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context));
    final dayLabel = _dayLabel(_gridStart);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          _timeNavFocusWrap(
            index: 0,
            child: IconButton(
              icon: const AppIcon(Symbols.chevron_left_rounded),
              onPressed: () => _shiftTimeRange(-2),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
            ),
          ),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                _timeNavFocusWrap(
                  index: 1,
                  child: ClickableCursor(
                    child: GestureDetector(
                      key: _dayPickerKey,
                      onTap: _showDayPicker,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: tokens(context).text.withValues(alpha: 0.08),
                          borderRadius: const BorderRadius.all(Radius.circular(MonoTokens.radiusFull)),
                        ),
                        child: Row(
                          mainAxisSize: .min,
                          children: [
                            Flexible(
                              child: Text(
                                dayLabel,
                                style: theme.textTheme.labelLarge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 2),
                            AppIcon(Symbols.arrow_drop_down_rounded, size: 18, color: theme.colorScheme.onSurface),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Text(timeLabel, style: theme.textTheme.labelLarge),
              ],
            ),
          ),
          _timeNavFocusWrap(
            index: 2,
            child: IconButton(
              icon: const AppIcon(Symbols.chevron_right_rounded),
              onPressed: () => _shiftTimeRange(2),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeHeader(ThemeData theme) {
    final is24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    final isTv = PlatformDetector.isTV();
    final colors = tokens(context);
    final slots = <Widget>[];
    var current = _gridStart;

    while (current.isBefore(_gridEnd)) {
      final timeStr = formatClockTime(current, is24Hour: is24Hour);
      slots.add(
        SizedBox(
          width: _slotWidth,
          child: Container(
            key: ValueKey('guide-time-slot-${current.millisecondsSinceEpoch}'),
            margin: isTv ? const EdgeInsets.all(2) : null,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: .centerLeft,
            decoration: isTv
                ? BoxDecoration(
                    color: colors.surface,
                    border: Border.all(color: colors.outline),
                    borderRadius: BorderRadius.circular(colors.radiusSm),
                  )
                : null,
            child: Text(
              timeStr,
              style: theme.textTheme.labelSmall?.copyWith(color: isTv ? colors.text : colors.textMuted),
            ),
          ),
        ),
      );
      current = current.add(const Duration(minutes: _minutesPerSlot));
    }

    return Row(children: slots);
  }

  Widget _buildSourceHeaderCell(String label, ThemeData theme) {
    return Container(
      height: _sourceHeaderRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: .centerLeft,
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: tokens(context).textMuted, fontWeight: .w700),
        maxLines: 2,
        overflow: .ellipsis,
      ),
    );
  }

  Widget _buildSourceHeaderGridRow(String label, ThemeData theme, {bool favorites = false}) {
    return SizedBox(
      height: _sourceHeaderRowHeight,
      child: ClipRect(
        child: ListenableBuilder(
          listenable: _gridHorizontalController,
          builder: (context, child) {
            final scrollOffset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
            return Transform.translate(offset: Offset(scrollOffset, 0), child: child);
          },
          child: Align(
            alignment: .centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: favorites && _canReorderFavorites
                  ? _GuideFocusSelector(
                      valueListenable: _focusSnapshot,
                      isSelected: (focus) => focus.hasFocus && focus.zone == _GuideZone.favorites,
                      builder: (context, focused) => Container(
                        decoration: FocusTheme.textFillFocusDecoration(
                          context,
                          isFocused: focused,
                          borderRadius: MonoTokens.radiusFull,
                        ),
                        child: TextButton.icon(
                          onPressed: widget.onReorderFavorites,
                          style: TextButton.styleFrom(foregroundColor: focused ? theme.colorScheme.onPrimary : null),
                          icon: const AppIcon(Symbols.swap_vert_rounded, size: 18),
                          label: Text(t.liveTv.reorderFavorites),
                        ),
                      ),
                    )
                  : Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: tokens(context).textMuted,
                        fontWeight: .w700,
                        letterSpacing: 0.3,
                      ),
                      maxLines: 1,
                      overflow: .ellipsis,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChannelCell(LiveTvChannel channel, ThemeData theme, {required int index}) {
    final multiServer = context.read<MultiServerProvider>();
    final serverId = serverIdOrNull(channel.serverId);
    final client = serverId == null ? null : multiServer.getClientForServer(serverId);

    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) =>
          focus.hasFocus && focus.zone == _GuideZone.grid && focus.gridColumn == 0 && focus.channelIndex == index,
      builder: (context, isFocused) {
        return _ChannelCell(
          rowHeight: _rowHeight,
          channelColumnWidth: _channelColumnWidth,
          channelThumb: channel.thumb,
          onHover: PlatformDetector.isTV()
              ? (hovered) => _hoverPreview.value = hovered ? (channel: channel, program: null) : null
              : null,
          client: client,
          channel: channel,
          theme: theme,
          onTap: () => tuneChannel(channel),
          onLongPress: widget.onToggleFavorite != null ? () => widget.onToggleFavorite!(channel) : null,
          isFocused: isFocused,
          isFavorite: widget.isFavoriteChannel?.call(channel) ?? false,
          fallbackBuilder: () => _buildChannelNameFallback(channel, theme),
        );
      },
    );
  }

  Widget _buildChannelNameFallback(LiveTvChannel channel, ThemeData theme) {
    return Column(
      mainAxisAlignment: .center,
      children: [
        if (channel.number != null)
          Text(
            channel.number!,
            style: theme.textTheme.labelSmall?.copyWith(color: tokens(context).textMuted),
            maxLines: 1,
          ),
        Text(
          channel.displayName,
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: .w500),
          maxLines: 1,
          overflow: .ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildProgramRow(
    LiveTvChannel channel,
    List<LiveTvProgram> programs,
    ThemeData theme, {
    required int channelIndex,
  }) {
    if (programs.isEmpty) {
      final tk = tokens(context);
      return SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: EdgeInsets.only(right: tk.groupGap, bottom: tk.groupGap),
          child: Material(
            color: Color.alphaBlend(tk.surface.withValues(alpha: 0.5), tk.bg),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(tk.radiusXs)),
            child: Center(
              child: Text(t.liveTv.noPrograms, style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted)),
            ),
          ),
        ),
      );
    }

    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final gridEndEpoch = _gridEnd.millisecondsSinceEpoch ~/ 1000;

    return SizedBox(
      height: _rowHeight,
      child: ListenableBuilder(
        listenable: _gridHorizontalController,
        builder: (context, _) {
          final scrollOffset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
          // Keep one slot of overscan so the next D-pad target exists before the horizontal jump.
          final visibleStart = scrollOffset > _slotWidth ? scrollOffset - _slotWidth : 0.0;
          final visibleEnd = scrollOffset + MediaQuery.sizeOf(context).width + _slotWidth;
          final blocks = <Widget>[];

          for (final program in programs) {
            final progStart = (program.beginsAt ?? gridStartEpoch).clamp(gridStartEpoch, gridEndEpoch);
            final progEnd = (program.endsAt ?? gridEndEpoch).clamp(gridStartEpoch, gridEndEpoch);
            if (progEnd <= progStart) continue;

            final startOffset = progStart - gridStartEpoch;
            final duration = progEnd - progStart;
            final left = (startOffset / (_minutesPerSlot * 60)) * _slotWidth;
            final width = (duration / (_minutesPerSlot * 60)) * _slotWidth;
            final clampedWidth = width.clamp(6.0, double.infinity);
            if (left + clampedWidth < visibleStart || left > visibleEnd) continue;

            blocks.add(
              Positioned(
                key: ObjectKey(program),
                left: left,
                width: clampedWidth,
                top: 0,
                bottom: 0,
                child: _buildProgramBlock(
                  channel,
                  program,
                  theme,
                  channelIndex: channelIndex,
                  tileLeft: left,
                  tileWidth: clampedWidth,
                  scrollOffset: scrollOffset,
                ),
              ),
            );
          }

          return Stack(children: blocks);
        },
      ),
    );
  }

  Widget _buildProgramBlock(
    LiveTvChannel channel,
    LiveTvProgram program,
    ThemeData theme, {
    required int channelIndex,
    required double tileLeft,
    required double tileWidth,
    required double scrollOffset,
  }) {
    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) =>
          focus.hasFocus &&
          focus.zone == _GuideZone.grid &&
          focus.gridColumn == 1 &&
          focus.channelIndex == channelIndex &&
          identical(focus.program, program),
      builder: (context, isFocused) {
        final tk = tokens(context);
        final isCurrentlyAiring = program.isCurrentlyAiring;
        final isPast = program.endsAt != null && program.endsAt! < clock.now().millisecondsSinceEpoch ~/ 1000;
        final isRecordingScheduled = _isRecordingScheduled(program);

        final Color fillColor;
        final Color titleColor;
        final Color subtitleColor;
        if (isFocused) {
          // Inverted focus card: primary == text in the mono theme, so the cursor
          // reads as a solid inverted cell (white card, dark text in dark mode).
          fillColor = theme.colorScheme.primary;
          titleColor = theme.colorScheme.onPrimary;
          subtitleColor = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
        } else if (isPast) {
          fillColor = Color.alphaBlend(tk.surface.withValues(alpha: 0.5), tk.bg);
          titleColor = tk.text.withValues(alpha: 0.5);
          subtitleColor = tk.text.withValues(alpha: 0.3);
        } else if (isCurrentlyAiring) {
          fillColor = airingFill(context);
          titleColor = tk.text;
          subtitleColor = tk.textMuted;
        } else {
          fillColor = tk.surface;
          titleColor = tk.text;
          subtitleColor = tk.textMuted;
        }
        final radius = BorderRadius.circular(isFocused ? tk.radiusSm : tk.radiusXs);

        return Padding(
          padding: EdgeInsets.only(right: tk.groupGap, bottom: tk.groupGap),
          child: Material(
            color: fillColor,
            shape: RoundedRectangleBorder(borderRadius: radius),
            child: InkWell(
              borderRadius: radius,
              mouseCursor: SystemMouseCursors.click,
              canRequestFocus: false,
              onHover: PlatformDetector.isTV()
                  ? (hovered) => _hoverPreview.value = hovered ? (channel: channel, program: program) : null
                  : null,
              onTap: () => _activateProgram(channel, program),
              onLongPress: () => _showProgramDetails(channel, program),
              onSecondaryTap: () => _showProgramDetails(channel, program),
              child: Padding(
                padding: .fromLTRB(
                  6 + (scrollOffset - tileLeft).clamp(0.0, (tileWidth - tk.groupGap - 32).clamp(0.0, double.infinity)),
                  4,
                  6,
                  4,
                ),
                child: _GuideProgramText(
                  program: program,
                  backgroundColor: fillColor,
                  titleColor: titleColor,
                  subtitleColor: subtitleColor,
                  isRecordingScheduled: isRecordingScheduled,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showProgramDetails(LiveTvChannel channel, LiveTvProgram program) {
    _pauseFollowingForProgram(program);
    showProgramDetails(
      program: program,
      channel: channel,
      posterThumb: program.thumb,
      posterServerId: channel.serverId,
      onRecordingStateChanged: (isScheduled) => _handleRecordingStateChanged(program, isScheduled),
    );
  }
}

/// The timeline can leave only a few pixels of an airing visible. Keep the
/// title flexible, omit decorations that cannot fit, and retain their semantics.
class _GuideProgramText extends StatelessWidget {
  const _GuideProgramText({
    required this.program,
    required this.backgroundColor,
    required this.titleColor,
    required this.subtitleColor,
    required this.isRecordingScheduled,
  });

  final LiveTvProgram program;
  final Color backgroundColor;
  final Color titleColor;
  final Color subtitleColor;
  final bool isRecordingScheduled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badge = switch (program.guideBadge) {
      GuideProgramBadge.live => t.liveTv.live,
      GuideProgramBadge.newProgram => t.liveTv.newProgram,
      null => null,
    };
    final subtitle = program.guideSubtitle;
    final badgeStyle = theme.textTheme.labelSmall?.copyWith(fontWeight: .w700);
    return Semantics(
      label: [program.guideTitle, ?badge, ?subtitle, if (isRecordingScheduled) t.liveTv.recordingScheduled].join(', '),
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final badgePainter = TextPainter(
            text: TextSpan(text: badge, style: badgeStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final badgeWidth = badgePainter.width + 8;
          badgePainter.dispose();
          final showRecording = isRecordingScheduled && constraints.maxWidth >= 28;
          final showBadge = badge != null && constraints.maxWidth >= badgeWidth + 36 + (showRecording ? 13 : 0);
          return ClipRect(
            child: Column(
              crossAxisAlignment: .start,
              mainAxisAlignment: .center,
              children: [
                Flexible(
                  child: Row(
                    children: [
                      if (showRecording) ...[
                        _RecordingDot(color: Colors.red, tooltip: t.liveTv.recordingScheduled),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          program.guideTitle,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: .w600, color: titleColor),
                          maxLines: 1,
                          overflow: .ellipsis,
                        ),
                      ),
                      if (showBadge) ...[
                        const SizedBox(width: 4),
                        if (program.guideBadge == GuideProgramBadge.live)
                          StatusPill.live()
                        else
                          StatusPill.newProgram(foregroundColor: titleColor, backgroundColor: backgroundColor),
                      ],
                    ],
                  ),
                ),
                if (subtitle != null)
                  Flexible(
                    child: Text(
                      subtitle,
                      style: theme.textTheme.labelSmall?.copyWith(color: subtitleColor),
                      maxLines: 1,
                      overflow: .ellipsis,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _GuideFocusSelector extends StatefulWidget {
  const _GuideFocusSelector({required this.valueListenable, required this.isSelected, required this.builder});

  final ValueListenable<_GuideFocusSnapshot> valueListenable;
  final bool Function(_GuideFocusSnapshot focus) isSelected;
  final Widget Function(BuildContext context, bool isSelected) builder;

  @override
  State<_GuideFocusSelector> createState() => _GuideFocusSelectorState();
}

class _GuideFocusSelectorState extends State<_GuideFocusSelector> {
  late bool _isSelected;

  @override
  void initState() {
    super.initState();
    _isSelected = widget.isSelected(widget.valueListenable.value);
    widget.valueListenable.addListener(_handleValueChanged);
  }

  @override
  void didUpdateWidget(_GuideFocusSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueListenable != widget.valueListenable) {
      oldWidget.valueListenable.removeListener(_handleValueChanged);
      widget.valueListenable.addListener(_handleValueChanged);
    }
    _isSelected = widget.isSelected(widget.valueListenable.value);
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_handleValueChanged);
    super.dispose();
  }

  void _handleValueChanged() {
    final isSelected = widget.isSelected(widget.valueListenable.value);
    if (isSelected == _isSelected) return;
    setState(() => _isSelected = isSelected);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _isSelected);
}

class _RecordingDot extends StatelessWidget {
  final Color color;
  final String tooltip;

  const _RecordingDot({required this.color, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _ChannelCell extends StatefulWidget {
  final double rowHeight;
  final double channelColumnWidth;
  final String? channelThumb;
  final MediaServerClient? client;
  final LiveTvChannel channel;
  final ThemeData theme;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final bool isFocused;
  final bool isFavorite;
  final Widget Function() fallbackBuilder;

  const _ChannelCell({
    required this.rowHeight,
    required this.channelColumnWidth,
    required this.channelThumb,
    required this.client,
    required this.channel,
    required this.theme,
    required this.onTap,
    this.onLongPress,
    this.onHover,
    required this.isFocused,
    this.isFavorite = false,
    required this.fallbackBuilder,
  });

  @override
  State<_ChannelCell> createState() => _ChannelCellState();
}

class _ChannelCellState extends State<_ChannelCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final tk = tokens(context);
    final showAction = _hovered || widget.isFocused;
    final radius = BorderRadius.circular(widget.isFocused ? tk.radiusSm : tk.radiusXs);
    // Inverted focus card, matching the program-block cursor.
    final contentColor = widget.isFocused ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHover?.call(true);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onHover?.call(false);
      },
      child: GestureDetector(
        onSecondaryTap: widget.onLongPress,
        child: SizedBox(
          height: widget.rowHeight,
          child: Padding(
            padding: EdgeInsets.only(right: tk.groupGap, bottom: tk.groupGap),
            child: Material(
              color: widget.isFocused ? theme.colorScheme.primary : tk.surface,
              shape: RoundedRectangleBorder(borderRadius: radius),
              child: InkWell(
                borderRadius: radius,
                canRequestFocus: false,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Stack(
                    alignment: .center,
                    children: [
                      AnimatedOpacity(
                        opacity: showAction ? 0.3 : 1.0,
                        duration: FocusTheme.getAnimationDuration(context),
                        child: widget.channelThumb != null && widget.client != null
                            ? OptimizedMediaImage.thumb(
                                client: widget.client!,
                                imagePath: widget.channelThumb,
                                width: widget.channelColumnWidth - 16,
                                height: widget.rowHeight - 16,
                                fit: BoxFit.contain,
                                logoToneTarget: logoToneTargetFor(
                                  surface: widget.isFocused ? theme.colorScheme.primary : tk.surface,
                                  foreground: widget.isFocused
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.onSurface,
                                ),
                              )
                            : widget.fallbackBuilder(),
                      ),
                      if (showAction) AppIcon(Symbols.play_arrow_rounded, size: 32, color: contentColor),
                      if (widget.isFavorite)
                        Positioned(
                          top: 2,
                          right: 0,
                          child: AppIcon(
                            Symbols.star_rounded,
                            size: 14,
                            color: widget.isFocused ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
