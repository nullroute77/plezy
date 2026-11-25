import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../models/livetv_channel.dart';
import '../../models/livetv_program.dart';
import '../../utils/content_utils.dart';
import '../../utils/formatters.dart';
import '../../utils/text_measure_cache.dart';

/// Read-only details for the airing highlighted in the TV guide.
class TvGuideProgramInfo extends StatelessWidget {
  const TvGuideProgramInfo({super.key, required this.channel, required this.program, required this.now});

  final LiveTvChannel? channel;
  final LiveTvProgram? program;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final airing = program;
    final season = airing?.parentIndex;
    final episode = airing?.index;
    final number = [if (season != null) 'S$season', if (episode != null) 'E$episode'].join();
    final subtitle = [if (number.isNotEmpty) number, ?airing?.guideSubtitle].join(' ');
    final start = airing?.startTime;
    final end = airing?.endTime;
    final rating = formatContentRating(airing?.contentRating?.trim());
    final is24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    final metadata = toBulletedString([
      if (channel != null && airing != null) channel!.displayName,
      if (start != null && end != null)
        '${formatClockTime(start, is24Hour: is24Hour)} – ${formatClockTime(end, is24Hour: is24Hour)}',
      if (rating.isNotEmpty) rating,
      if (start != null && end != null && !now.isBefore(start) && now.isBefore(end))
        t.discover.minutesLeft(minutes: (end.difference(now).inMicroseconds / Duration.microsecondsPerMinute).ceil()),
    ]);
    final title = airing?.guideTitle ?? channel?.displayName ?? t.liveTv.guide;
    final summary = airing == null ? t.liveTv.noPrograms : airing.summary?.trim() ?? '';
    final theme = Theme.of(context).textTheme;

    return ExcludeFocus(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final textScaler = MediaQuery.textScalerOf(context);
            final textDirection = Directionality.of(context);
            final titleStyle = theme.headlineMedium!.copyWith(fontWeight: FontWeight.w600);
            final subtitleStyle = theme.titleLarge!;
            final metadataStyle = theme.titleMedium!;
            final summaryStyle = theme.bodyLarge!;
            Size measure(String text, TextStyle style) =>
                cachedSingleLineTextSize(text, style: style, textScaler: textScaler, textDirection: textDirection);

            var remaining = constraints.maxHeight - measure(title, titleStyle).height;
            final subtitleHeight = measure(subtitle, subtitleStyle).height + 4;
            final showSubtitle = subtitle.isNotEmpty && remaining >= subtitleHeight;
            if (showSubtitle) remaining -= subtitleHeight;
            final metadataSize = measure(metadata, metadataStyle);
            final showMetadata = metadata.isNotEmpty && remaining >= metadataSize.height + 4;
            final metadataLines = metadataSize.width > constraints.maxWidth && remaining >= metadataSize.height * 2 + 4
                ? 2
                : 1;
            if (showMetadata) remaining -= metadataSize.height * metadataLines + 4;
            final summaryLineHeight = measure(summary, summaryStyle).height;
            final summaryLines = summary.isEmpty || summaryLineHeight == 0
                ? 0
                : ((remaining - 8) / summaryLineHeight).floor().clamp(0, 3);

            return Align(
              alignment: AlignmentDirectional.centerStart,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(title, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  if (showSubtitle) ...[
                    const SizedBox(height: 4),
                    Text(subtitle, style: subtitleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                  if (showMetadata) ...[
                    const SizedBox(height: 4),
                    Text(metadata, style: metadataStyle, maxLines: metadataLines, overflow: TextOverflow.ellipsis),
                  ],
                  if (summaryLines > 0) ...[
                    const SizedBox(height: 8),
                    Text(summary, style: summaryStyle, maxLines: summaryLines, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
