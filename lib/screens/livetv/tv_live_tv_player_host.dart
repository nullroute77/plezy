import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../widgets/tv_backdrop_scrim.dart';
import '../../widgets/overlay_sheet.dart';
import '../../utils/video_player_navigation.dart';
import '../video_player/live_tv_player_presentation.dart';
import '../video_player/live_tv_session_args.dart';
import '../video_player_screen.dart';
import 'tv_live_tv_playback_scope.dart';

/// Moves the keyed guide into the normal opaque player route on first tune.
/// Keeping that route while browsing lets native video show through Flutter,
/// with one player and one guide mounted through fullscreen/back transitions.
class TvLiveTvPlayerHost extends StatefulWidget {
  final WidgetBuilder builder;
  final VoidCallback onGuideShown;
  final bool active;

  const TvLiveTvPlayerHost({super.key, required this.builder, required this.onGuideShown, this.active = true});

  @override
  State<TvLiveTvPlayerHost> createState() => _TvLiveTvPlayerHostState();
}

class _TvLiveTvPlayerHostState extends State<TvLiveTvPlayerHost> {
  final _revision = ValueNotifier(0);
  PageRoute<bool>? _route;
  final _contentKey = GlobalKey();
  final _playerKey = GlobalKey<VideoPlayerScreenState>();
  MediaItem? _metadata;
  LiveTvSessionArgs? _live;
  bool _fullscreen = false;
  bool _stopping = false;
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerMode = TickerMode.getValuesNotifier(context);
    if (_tickerMode != tickerMode) {
      _tickerMode?.removeListener(_visibilityChanged);
      _tickerMode = tickerMode..addListener(_visibilityChanged);
    }
    _visibilityChanged();
  }

  @override
  void didUpdateWidget(TvLiveTvPlayerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && _live != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.active) unawaited(_stop());
      });
    }
    // The route lives outside this element; propagate parent tab/favorite updates.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _route != null) _revision.value++;
    });
  }

  void _visibilityChanged() {
    if (_route == null && (!widget.active || _tickerMode?.value.enabled == false) && _live != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (!widget.active || _tickerMode?.value.enabled == false)) unawaited(_stop());
      });
    }
  }

  Future<void> _play(MediaItem metadata, LiveTvSessionArgs live) async {
    if (_stopping) return;
    if (_live != null) {
      final selected = await _playerKey.currentState?.selectHostedLiveChannel(live.channel) ?? false;
      if (!mounted || _stopping || !selected) return;
      _fullscreen = true;
      _revision.value++;
    } else {
      _metadata = metadata;
      _live = live;
      _fullscreen = true;
      final route = buildVideoPlayerRoute(
        builder: (_) => ValueListenableBuilder(
          valueListenable: _revision,
          builder: (_, _, _) => _route == null ? const SizedBox.shrink() : _buildContent(),
        ),
      );
      setState(() => _route = route);
      unawaited(
        Navigator.of(context).push<bool>(route).then((_) {
          if (mounted && identical(_route, route)) _clearPlayback(popRoute: false);
        }),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _playerKey.currentState?.focusHostedPlayer());
  }

  void _showGuide() {
    if (!_fullscreen) return;
    _fullscreen = false;
    _revision.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onGuideShown();
    });
  }

  Future<void> _stop() async {
    if (_stopping || _live == null) return;
    _stopping = true;
    await _playerKey.currentState?.stopHostedPlayback();
    if (!mounted) return;
    _clearPlayback();
  }

  void _clearPlayback({bool popRoute = true}) {
    if (!mounted) return;
    final route = _route;
    setState(() {
      _route = null;
      _metadata = null;
      _live = null;
      _fullscreen = false;
      _stopping = false;
    });
    _revision.value++;
    if (popRoute && route != null) {
      final navigator = route.navigator;
      if (route.isCurrent) {
        navigator?.pop();
      } else {
        navigator?.removeRoute(route);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tickerMode?.value.enabled == true) widget.onGuideShown();
    });
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_visibilityChanged);
    _revision.dispose();
    super.dispose();
  }

  Widget _buildContent() => KeyedSubtree(
    key: _contentKey,
    child: TvLiveTvPlaybackScope(
      play: _play,
      enabled: widget.active,
      exitGuide: _stop,
      hasPlayback: _live != null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_live != null)
            Positioned.fill(
              child: ExcludeFocus(
                excluding: !_fullscreen,
                child: IgnorePointer(
                  ignoring: !_fullscreen,
                  child: VideoPlayerScreen(
                    key: _playerKey,
                    metadata: _metadata!,
                    live: _live,
                    livePresentation: LiveTvPlayerPresentation(
                      background: !_fullscreen,
                      onReturnToGuide: _showGuide,
                      onExit: _clearPlayback,
                    ),
                  ),
                ),
              ),
            ),
          if (_live != null && !_fullscreen) const Positioned.fill(child: TvBackdropScrim()),
          Positioned.fill(
            key: const ValueKey('tv-guide-content'),
            child: Offstage(
              offstage: _fullscreen,
              child: ExcludeFocus(
                excluding: _fullscreen,
                child: OverlaySheetHost(
                  canPop: _live == null || _fullscreen,
                  onSystemBack: _fullscreen || _live == null ? null : () => unawaited(_stop()),
                  child: Builder(builder: widget.builder),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => _route != null ? const SizedBox.expand() : _buildContent();
}
