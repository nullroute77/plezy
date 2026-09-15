import 'package:flutter/foundation.dart';

/// A TV guide owns this player instead of a separate player route. Returning
/// to the guide changes presentation only; explicit exit still stops playback.
class LiveTvPlayerPresentation {
  final bool background;
  final VoidCallback onReturnToGuide;
  final VoidCallback onExit;

  const LiveTvPlayerPresentation({required this.background, required this.onReturnToGuide, required this.onExit});
}
