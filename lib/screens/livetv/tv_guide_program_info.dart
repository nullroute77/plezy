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
            final posterHeight = constraints.maxHeight.clamp(0.0, 220.0);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (poster != null && client != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(tokens(context).radiusMd),
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
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: (constraints.maxWidth * 0.7).clamp(280.0, 900.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              airing?.guideTitle ?? channel?.displayName ?? t.liveTv.guide,
                              style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (subtitle.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                subtitle,
                                style: theme.textTheme.titleLarge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            if (metadata.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                metadata,
                                style: theme.textTheme.titleMedium,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(height: 12),
                            Text(
                              airing?.summary?.trim().isNotEmpty == true
                                  ? airing!.summary!
                                  : (airing == null ? t.liveTv.noPrograms : ''),
                              style: theme.textTheme.bodyLarge,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
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
