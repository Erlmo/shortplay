import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../models/episode.dart';
import '../episode_selector.dart';

Future<void> showPlayerEpisodeSheet({
  required BuildContext context,
  required bool isLandscapeFullScreen,
  required String dramaName,
  required List<Episode> episodes,
  required ValueListenable<int> episodeNotifier,
  required ValueChanged<int> onSelectEpisode,
}) {
  if (isLandscapeFullScreen) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (context) {
        final media = MediaQuery.of(context);
        return Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: _EpisodeSheetPanel(
              width: media.size.width * 0.7,
              height: media.size.height * 0.7,
              dramaName: dramaName,
              episodes: episodes,
              episodeNotifier: episodeNotifier,
              onSelectEpisode: onSelectEpisode,
              titleVerticalPadding: 16,
            ),
          ),
        );
      },
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: false,
    builder: (context) {
      final media = MediaQuery.of(context);
      final bottomPadding =
          (media.viewPadding.bottom * 0.5).clamp(8.0, 18.0).toDouble();

      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: _EpisodeSheetPanel(
          height: media.size.height * 0.45 + bottomPadding,
          bottomPadding: bottomPadding,
          dramaName: dramaName,
          episodes: episodes,
          episodeNotifier: episodeNotifier,
          onSelectEpisode: onSelectEpisode,
          showHandle: true,
        ),
      );
    },
  );
}

class _EpisodeSheetPanel extends StatelessWidget {
  const _EpisodeSheetPanel({
    required this.height,
    required this.dramaName,
    required this.episodes,
    required this.episodeNotifier,
    required this.onSelectEpisode,
    this.width,
    this.bottomPadding = 0,
    this.titleVerticalPadding = 12,
    this.showHandle = false,
  });

  final double? width;
  final double height;
  final double bottomPadding;
  final double titleVerticalPadding;
  final bool showHandle;
  final String dramaName;
  final List<Episode> episodes;
  final ValueListenable<int> episodeNotifier;
  final ValueChanged<int> onSelectEpisode;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: width == null ? 0.1 : 0.2),
            blurRadius: width == null ? 10 : 20,
            offset: width == null ? const Offset(0, -2) : const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: Column(
          children: [
            if (showHandle)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            _EpisodeSheetHeader(
              dramaName: dramaName,
              episodeCount: episodes.length,
              verticalPadding: titleVerticalPadding,
            ),
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: episodeNotifier,
                builder: (context, currentIndex, _) {
                  return EpisodeSelector(
                    episodes: episodes,
                    activeIndex: currentIndex,
                    onSelect: (index) {
                      Navigator.of(context).pop();
                      onSelectEpisode(index);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeSheetHeader extends StatelessWidget {
  const _EpisodeSheetHeader({
    required this.dramaName,
    required this.episodeCount,
    required this.verticalPadding,
  });

  final String dramaName;
  final int episodeCount;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: verticalPadding),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dramaName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF1A1A1A),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 4,
                      height: 4,
                      decoration: const BoxDecoration(
                        color: Color(0xFF4ADE80),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '更新至 $episodeCount 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF757575),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: Color(0xFF424242),
                  size: 18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
