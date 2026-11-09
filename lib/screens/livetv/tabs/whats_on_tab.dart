import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../focus/hub_vertical_navigation.dart';
import '../../../focus/locked_hub_controller.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/ids.dart';
import '../../../media/media_hub.dart';
import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../media/media_server_client.dart';
import '../../../media/media_item_types.dart';
import '../../../mixins/mounted_set_state_mixin.dart';
import '../../../models/livetv_channel.dart';
import '../../../models/livetv_hub_result.dart';
import '../../../providers/multi_server_provider.dart';
import '../../../services/settings_service.dart';
import '../../../utils/app_logger.dart';
import '../../../widgets/hub_section.dart';
import '../live_tv_actions_mixin.dart';
import '../live_tv_show_schedule_screen.dart';
import '../live_tv_refresh_mixin.dart';
import '../live_tv_server_iteration.dart';

class WhatsOnTab extends StatefulWidget {
  final List<LiveTvChannel> channels;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onBack;

  const WhatsOnTab({super.key, required this.channels, this.onNavigateUp, this.onBack});

  @override
  State<WhatsOnTab> createState() => WhatsOnTabState();
}

class WhatsOnTabState extends State<WhatsOnTab>
    with LiveTvActionsMixin<WhatsOnTab>, MountedSetStateMixin, WidgetsBindingObserver, LiveTvRefreshMixin<WhatsOnTab> {
  List<_WhatsOnHub> _hubs = [];
  bool _isLoading = true;
  int _loadGeneration = 0;
  final Map<String, GlobalKey<HubSectionState>> _hubKeysById = {};
  List<GlobalKey<HubSectionState>> _hubKeys = [];
  final _hubFocusMemory = HubFocusMemory();

  @override
  List<LiveTvChannel> get liveTvChannels => widget.channels;

  @override
  Duration get refreshInterval => const Duration(seconds: 60);

  @override
  void onRefreshTick() => unawaited(_loadHubs());

  @override
  void onRefreshResumed(LiveTvRefreshResumeReason reason) => unawaited(_loadHubs());

  @override
  void initState() {
    super.initState();
    _loadHubs();
  }

  Future<void> _loadHubs() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final now = clock.now();
    setState(() => _isLoading = _hubs.isEmpty);

    try {
      final multiServer = context.read<MultiServerProvider>();
      final allHubs = <_WhatsOnHub>[];
      final allHubIds = <String>[];

      await forEachLiveTvServer(
        multiServer,
        resolveClient: multiServer.getClientForServer,
        isCurrent: () => mounted && generation == _loadGeneration,
        body: (client, serverInfo) async {
          final plex = multiServer.getPlexClientForServer(client.serverId);
          final hubs = plex != null ? await plex.getLiveTvHubs() : await _loadCurrentPrograms(client, now);
          for (final hub in hubs) {
            allHubs.add(_WhatsOnHub.fromResult(hub, client: client));
            allHubIds.add('${serverInfo.serverId}\u0000${hub.hubKey}');
          }
        },
        onError: (client, serverInfo, error, stackTrace) {
          appLogger.e('Failed to load hubs from server ${serverInfo.serverId}', error: error);
        },
      );

      if (!mounted || generation != _loadGeneration) return;
      final hubIds = allHubIds.toSet();
      _hubKeysById.removeWhere((id, _) => !hubIds.contains(id));
      setState(() {
        _hubs = allHubs;
        _hubKeys = [for (final hubId in allHubIds) _hubKeysById.putIfAbsent(hubId, () => GlobalKey<HubSectionState>())];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      appLogger.e('Failed to load live TV hubs', error: e);
      setStateIfMounted(() => _isLoading = false);
    }
  }

  /// MediaBrowser servers have schedules rather than Plex discovery hubs.
  /// Reuse their parsed programs so details, recordings, and tuning retain
  /// the original airing metadata and owning server.
  Future<List<LiveTvHubResult>> _loadCurrentPrograms(MediaServerClient client, DateTime now) async {
    // Keep a nonempty window, including programs starting at this second.
    // Filter below because overlap responses can also include future entries.
    final programs = await client.liveTv.fetchSchedule(from: now, to: now.add(const Duration(seconds: 1)));
    final epoch = now.millisecondsSinceEpoch ~/ 1000;
    final entries = <LiveTvHubEntry>[];
    for (final program in programs) {
      final start = program.beginsAt;
      final end = program.endsAt;
      if (start == null || end == null || start > epoch || end <= epoch) continue;
      entries.add(
        LiveTvHubEntry(
          program: program,
          metadata: MediaItem(
            id: program.ratingKey ?? program.key ?? '${program.channelIdentifier}:$start',
            backend: client.backend,
            kind: MediaKind.clip,
            title: program.guideTitle,
            summary: program.summary,
            contentRating: program.contentRating,
            thumbPath: program.thumb,
            artPath: program.art,
            durationMs: (end - start) * 1000,
            serverId: client.serverId,
            serverName: client.serverName,
          ),
        ),
      );
    }
    if (entries.isEmpty) return const [];
    return [LiveTvHubResult(title: t.liveTv.whatsOn, hubKey: 'currently-airing', entries: entries)];
  }

  /// Focus the first hub (called from parent when tab bar navigates down)
  void focusFirstHub() {
    if (_hubKeys.isNotEmpty) {
      _hubKeys.first.currentState?.requestFocusFromMemory();
    }
  }

  bool _handleVerticalNavigation(int hubIndex, bool isUp) {
    return navigateVerticalHubRows(
      hubCount: _hubKeys.length,
      hubIndex: hubIndex,
      isUp: isUp,
      onTopBoundary: widget.onNavigateUp,
      requestFocus: (targetIndex) {
        _hubKeys[targetIndex].currentState?.requestFocusFromMemory();
      },
    );
  }

  void _onItemTap(LiveTvHubEntry entry) {
    final channel = findChannelForProgram(entry.program);

    if (entry.program.isCurrentlyAiring && channel != null) {
      // Live → play directly
      tuneChannel(channel);
    } else if (entry.metadata.isShow && serverIdOrNull(entry.metadata.serverId) != null) {
      // Show with upcoming episodes → show full schedule
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LiveTvShowScheduleScreen(
            showTitle: entry.metadata.displayTitle,
            serverId: entry.metadata.serverId!,
            channels: widget.channels,
          ),
        ),
      );
    } else {
      // Individual program (episode, movie, etc.) → bottom sheet
      showProgramDetails(
        program: entry.program,
        channel: channel,
        posterThumb: entry.metadata.grandparentThumbPath ?? entry.metadata.thumbPath,
        posterServerId: entry.metadata.serverId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_hubs.isEmpty) {
      return Center(child: Text(t.liveTv.noPrograms));
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      clipBehavior: Clip.none,
      itemCount: _hubs.length,
      itemBuilder: (context, index) {
        final hub = _hubs[index];
        return HubSection(
          key: _hubKeys[index],
          hub: hub.mediaHub,
          showServerName: true,
          focusMemory: _hubFocusMemory,
          icon: Symbols.live_tv_rounded,
          cardSizing: HubCardSizing.grid,
          episodePosterModeOverride: EpisodePosterMode.seriesPoster,
          onItemTap: (item) => _onItemTap(hub.entryFor(item)),
          onItemLongPress: (item) {
            final entry = hub.entryFor(item);
            showProgramDetails(
              program: entry.program,
              channel: findChannelForProgram(entry.program),
              posterThumb: entry.metadata.grandparentThumbPath ?? entry.metadata.thumbPath,
              posterServerId: entry.metadata.serverId,
            );
          },
          onVerticalNavigation: (isUp) => _handleVerticalNavigation(index, isUp),
          onNavigateToSidebar: widget.onBack,
          onBack: widget.onBack,
        );
      },
    );
  }
}

class _WhatsOnHub {
  final MediaHub mediaHub;
  final Map<MediaItem, LiveTvHubEntry> _entriesByItem;

  const _WhatsOnHub._(this.mediaHub, this._entriesByItem);

  factory _WhatsOnHub.fromResult(LiveTvHubResult result, {required MediaServerClient client}) {
    final entriesByItem = Map<MediaItem, LiveTvHubEntry>.identity();
    for (final entry in result.entries) {
      entriesByItem[entry.metadata] = entry;
    }

    return _WhatsOnHub._(
      MediaHub(
        id: result.hubKey,
        title: result.title,
        type: 'mixed',
        items: [for (final entry in result.entries) entry.metadata],
        size: result.entries.length,
        serverId: client.serverId,
        serverName: client.serverName,
      ),
      entriesByItem,
    );
  }

  LiveTvHubEntry entryFor(MediaItem item) => _entriesByItem[item]!;
}
