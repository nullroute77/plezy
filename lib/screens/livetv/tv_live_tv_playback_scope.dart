import 'package:flutter/widgets.dart';

import '../../media/media_item.dart';
import '../video_player/live_tv_session_args.dart';

/// Only the TV Live TV screen installs this scope. Other live playback entry
/// points continue to use the ordinary player route.
class TvLiveTvPlaybackScope extends InheritedWidget {
  final Future<void> Function(MediaItem metadata, LiveTvSessionArgs live) play;
  final bool hasPlayback;
  final bool enabled;
  final Future<void> Function()? exitGuide;

  const TvLiveTvPlaybackScope({
    super.key,
    required this.play,
    required this.hasPlayback,
    this.enabled = true,
    this.exitGuide,
    required super.child,
  });

  static TvLiveTvPlaybackScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvLiveTvPlaybackScope>();

  @override
  bool updateShouldNotify(TvLiveTvPlaybackScope oldWidget) =>
      hasPlayback != oldWidget.hasPlayback || enabled != oldWidget.enabled;
}
