import 'package:flutter/material.dart';

import '../../theme/mono_tokens.dart';

/// Fill for "currently airing" live TV cards: one text-alpha step above the
/// idle surface card. Shared by the guide's airing blocks, the recordings
/// tab's in-progress tile, and the show schedule's live tile.
Color airingFill(BuildContext context) {
  final tk = tokens(context);
  return Color.alphaBlend(tk.text.withValues(alpha: 0.08), tk.surface);
}

/// Tinted M3E status pill (LIVE badge, recording / error state).
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool _compact;

  const StatusPill({super.key, required this.label, required this.color}) : _compact = false;

  /// Solid, compact badge for inline guide titles. Keep its white foreground
  /// independent of the card's inverted focus colors.
  const StatusPill.compact({super.key, required this.label, required this.color}) : _compact = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: _compact ? 4 : 8, vertical: _compact ? 1 : 4),
      decoration: BoxDecoration(
        color: _compact ? color : color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.all(Radius.circular(_compact ? 3 : MonoTokens.radiusFull)),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: _compact ? Colors.white : color, fontWeight: .w700),
        maxLines: _compact ? 1 : null,
      ),
    );
  }
}
