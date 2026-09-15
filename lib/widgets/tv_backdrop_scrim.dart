import 'package:flutter/material.dart';

import 'rasterized_gradient.dart';

/// Shared TV detail/guide shading; the media underneath may be artwork or video.
class TvBackdropScrim extends StatelessWidget {
  const TvBackdropScrim({super.key});

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).scaffoldBackgroundColor;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          RasterizedGradient(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [background.withValues(alpha: 0.86), background.withValues(alpha: 0.32), Colors.transparent],
              stops: const [0.0, 0.56, 1.0],
            ),
          ),
          RasterizedGradient(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: 0.45), Colors.transparent, background.withValues(alpha: 0.96)],
              stops: const [0.0, 0.38, 1.0],
            ),
          ),
        ],
      ),
    );
  }
}
