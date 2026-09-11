import 'package:flutter/material.dart';

import '../../theme/mono_tokens.dart';

/// Fill for "currently airing" live TV cards: one text-alpha step above the
/// idle surface card. Shared by the guide's airing blocks, the recordings
/// tab's in-progress tile, and the show schedule's live tile.
Color airingFill(BuildContext context) {
  final tk = tokens(context);
  return Color.alphaBlend(tk.text.withValues(alpha: 0.08), tk.surface);
}
