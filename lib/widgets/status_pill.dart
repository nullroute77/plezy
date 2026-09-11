import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../theme/mono_tokens.dart';

/// Shared status label: a tinted pill or compact, filled badge.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final Color foregroundColor;
  final bool _compact;

  const StatusPill({super.key, required this.label, required this.color}) : foregroundColor = color, _compact = false;

  /// Solid, compact badge for inline guide titles. Neutral badges can supply
  /// the card's foreground; broadcast status badges default to white.
  const StatusPill.compact({super.key, required this.label, required this.color, this.foregroundColor = Colors.white})
    : _compact = true;

  /// One localized LIVE appearance shared by guide, player, and details.
  factory StatusPill.live({Key? key}) => StatusPill.compact(key: key, label: t.liveTv.live, color: Colors.red.shade700);

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
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foregroundColor, fontWeight: .w700),
        maxLines: _compact ? 1 : null,
        textAlign: _compact ? TextAlign.center : null,
        textHeightBehavior: _compact
            ? const TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even)
            : null,
      ),
    );
  }
}
