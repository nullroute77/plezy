import 'package:flutter/material.dart';
import 'package:clock/clock.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../models/livetv_channel.dart';
import '../../models/livetv_program.dart';
import '../../providers/multi_server_provider.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/content_utils.dart';
import '../../utils/formatters.dart';
import '../../utils/text_measure_cache.dart';
import '../../widgets/optimized_media_image.dart';

/// The highlighted airing's details, independent of the channel being played.
class TvGuideProgramInfo extends StatelessWidget {
  final LiveTvChannel? channel;
  final LiveTvProgram? program;

  const TvGuideProgramInfo({super.key, required this.channel, required this.program});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final airing = program;
    final poster = airing?.poster ?? airing?.thumb;
    final serverId = serverIdOrNull(airing?.serverId ?? channel?.serverId);
    final client = serverId == null ? null : context.read<MultiServerProvider>().getClientForServer(serverId);
    final episode =
        formatSeasonEpisodeLabel(airing?.parentIndex, airing?.index, compact: true) ??
        (airing?.index != null
            ? 'E${airing!.index}'
            : airing?.parentIndex != null
            ? 'S${airing!.parentIndex}'
            : null);
    final programRating = formatContentRating(airing?.contentRating?.trim());
    final rating = programRating.isNotEmpty ? programRating : formatContentRating(channel?.contentRating?.trim());
    final now = clock.now();
    final start = airing?.startTime;
    final end = airing?.endTime;
    final is24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    final subtitle = [?episode, ?airing?.guideSubtitle].join(' ');
    final metadata = [
      if (channel != null && airing != null) channel!.displayName,
      if (start != null && end != null)
        '${formatClockTime(start, is24Hour: is24Hour)} – ${formatClockTime(end, is24Hour: is24Hour)}',
      if (rating.isNotEmpty) rating,
      if (start != null && end != null && !now.isBefore(start) && now.isBefore(end))
        t.discover.minutesLeft(minutes: (end.difference(now).inSeconds / 60).ceil()),
    ].join(' • ');

    return ExcludeFocus(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 24, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final posterHeight = constraints.maxHeight.clamp(0.0, 220.0).clamp(0.0, constraints.maxWidth / 3);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (poster != null && client != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(tokens(context).radiusSm),
                    child: OptimizedMediaImage.thumb(
                      client: client,
                      imagePath: poster,
                      width: posterHeight * 2 / 3,
                      height: posterHeight,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 24),
                ],
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: LayoutBuilder(
                      builder: (context, textConstraints) {
                        final title = airing?.guideTitle ?? channel?.displayName ?? t.liveTv.guide;
                        final summary = airing?.summary?.trim().isNotEmpty == true
                            ? airing!.summary!
                            : (airing == null ? t.liveTv.noPrograms : '');
                        final titleStyle = theme.textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w600);
                        final subtitleStyle = theme.textTheme.titleLarge!;
                        final metadataStyle = theme.textTheme.titleMedium!;
                        final summaryStyle = theme.textTheme.bodyLarge!;
                        Size measure(String text, TextStyle style) => cachedSingleLineTextSize(
                          text,
                          style: style,
                          textScaler: MediaQuery.textScalerOf(context),
                          textDirection: Directionality.of(context),
                        );

                        // Keep theme font sizes, spending the available height on the
                        // title and metadata before the description. Never scale the
                        // whole panel to fit a long description or a narrow column.
                        var remaining = textConstraints.maxHeight - measure(title, titleStyle).height;
                        final subtitleHeight = measure(subtitle, subtitleStyle).height;
                        final showSubtitle = subtitle.isNotEmpty && remaining >= subtitleHeight + 8;
                        if (showSubtitle) remaining -= subtitleHeight + 8;
                        final metadataSize = measure(metadata, metadataStyle);
                        final showMetadata = metadata.isNotEmpty && remaining >= metadataSize.height + 10;
                        final metadataLines =
                            metadataSize.width > textConstraints.maxWidth && remaining >= metadataSize.height * 2 + 10
                            ? 2
                            : 1;
                        if (showMetadata) remaining -= metadataSize.height * metadataLines + 10;
                        final summaryHeight = measure(summary, summaryStyle).height;
                        final summaryLines = summary.isEmpty || summaryHeight == 0
                            ? 0
                            : ((remaining - 12) / summaryHeight).floor().clamp(0, 3);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Flexible(
                              child: Text(title, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            if (showSubtitle) ...[
                              const SizedBox(height: 8),
                              Text(subtitle, style: subtitleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                            if (showMetadata) ...[
                              const SizedBox(height: 10),
                              Text(
                                metadata,
                                style: metadataStyle,
                                maxLines: metadataLines,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            if (summaryLines > 0) ...[
                              const SizedBox(height: 12),
                              Text(
                                summary,
                                style: summaryStyle,
                                maxLines: summaryLines,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
