import 'package:flutter/material.dart';

import '../models/episode.dart';
import 'episode_selector.dart';

const detailAccent = Color(0xFFFF4D4F);

/// 详情页只展示一排选集，其余集数通过完整目录选择。
class DetailEpisodeStrip extends StatelessWidget {
  const DetailEpisodeStrip({
    super.key,
    required this.episodes,
    required this.onSelect,
    required this.onShowAll,
  });

  final List<Episode> episodes;
  final ValueChanged<int> onSelect;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final count = episodes.length.clamp(0, 12);
    return SizedBox(
      height: 56,
      child: ListView.separated(
        key: const ValueKey('detail-episode-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: count + (episodes.length > count ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == count) {
            return TextButton(
              onPressed: onShowAll,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF6B7280),
                backgroundColor: const Color(0xFFF4F5F7),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('更多 ›', style: TextStyle(fontSize: 12)),
            );
          }
          final active = index == 0;
          return Semantics(
            label: '第${episodes[index].index}集',
            selected: active,
            button: true,
            child: Material(
              key: ValueKey('episode-$index'),
              color: active ? detailAccent : const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: () => onSelect(index),
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('${episodes[index].index}',
                          style: TextStyle(
                              fontSize: 13,
                              height: 1,
                              fontWeight: FontWeight.w600,
                              color: active
                                  ? Colors.white
                                  : const Color(0xFF1F2937))),
                      if (active) ...[
                        const SizedBox(height: 5),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final height in [3.0, 7.0, 5.0])
                              Container(
                                width: 2,
                                height: height,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 1),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(1),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Future<int?> showDetailEpisodesSheet({
  required BuildContext context,
  required String title,
  required String seasonLabel,
  required List<Episode> episodes,
}) =>
    showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (context) => SafeArea(
        top: false,
        child: SizedBox(
          key: const ValueKey('detail-all-episodes'),
          height: (MediaQuery.sizeOf(context).height * .65).clamp(260.0, 560.0),
          child: Column(children: [
            const SizedBox(height: 10),
            Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(4))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text('$seasonLabel共${episodes.length}集',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9CA3AF))),
                    ],
                  ),
                ),
                IconButton(
                    tooltip: '关闭选集',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 21)),
              ]),
            ),
            Expanded(
              child: EpisodeSelector(
                episodes: episodes,
                activeIndex: 0,
                autofocusActive: false,
                softStyle: true,
                horizontalPadding: 16,
                onSelect: (index) => Navigator.of(context).pop(index),
              ),
            ),
          ]),
        ),
      ),
    );
