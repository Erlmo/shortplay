import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/playback_record.dart';
import '../../services/api_client.dart';
import '../../services/download_service.dart';
import '../../services/playback_history_store.dart';
import '../../widgets/tv_tap.dart';
import '../playback_record_launcher.dart';

/// 首页顶部“继续观看”：最近看过的剧横向排列，点一下回到上次的那一集和进度。
/// 下面带一个“为你推荐”标题，和推荐流隔开。没有播放记录时整块不占位。
class ContinueWatchingRow extends StatefulWidget {
  const ContinueWatchingRow({
    super.key,
    required this.apiClient,
    this.downloadService,
    this.onShowAll,
  });

  final ApiClient apiClient;
  final DownloadService? downloadService;

  /// 点“全部”时跳到历史页；为 null 时不显示“全部”。
  final VoidCallback? onShowAll;

  /// 最多展示几部。
  static const int maxItems = 10;

  @override
  State<ContinueWatchingRow> createState() => _ContinueWatchingRowState();
}

class _ContinueWatchingRowState extends State<ContinueWatchingRow> {
  List<PlaybackRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _load();
    PlaybackHistoryStore.revision.addListener(_load);
  }

  @override
  void dispose() {
    PlaybackHistoryStore.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final records = await PlaybackHistoryStore.load();
    if (!mounted) return;
    setState(() {
      _records = records
          .where((r) => r.dramaId != 0)
          .take(ContinueWatchingRow.maxItems)
          .toList(growable: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_records.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(children: [
              const Text('继续观看', style: _sectionTitleStyle),
              const Spacer(),
              if (widget.onShowAll != null)
                TvTap(
                  borderRadius: 12,
                  onTap: widget.onShowAll,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('全部',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF999999))),
                      Icon(Icons.chevron_right_rounded,
                          size: 16, color: Color(0xFF999999)),
                    ]),
                  ),
                ),
            ]),
          ),
          SizedBox(
            height: _ContinueWatchingCard.height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _records.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final record = _records[index];
                return _ContinueWatchingCard(
                  key: ValueKey('continue-${record.dramaId}'),
                  record: record,
                  onTap: () => openPlaybackRecord(
                    context,
                    record: record,
                    apiClient: widget.apiClient,
                    downloadService: widget.downloadService,
                  ),
                );
              },
            ),
          ),
          // 与下方推荐流隔开：留白 + 分区标题
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 22, 16, 0),
            child: Text('为你推荐', style: _sectionTitleStyle),
          ),
        ],
      ),
    );
  }
}

const _sectionTitleStyle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w700,
  color: Color(0xFF1D1D1F),
);

class _ContinueWatchingCard extends StatelessWidget {
  const _ContinueWatchingCard({
    super.key,
    required this.record,
    required this.onTap,
  });

  final PlaybackRecord record;
  final VoidCallback onTap;

  static const double width = 104;
  static const double coverHeight = 138;
  static const double height = coverHeight + 44;

  @override
  Widget build(BuildContext context) {
    final episode = record.episodeNumber ?? record.episodeIndex + 1;
    final progress = record.episodeProgress;
    final count = record.episodeCount;
    return SizedBox(
      width: width,
      child: TvTap(
        borderRadius: 8,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: width,
                height: coverHeight,
                child: Stack(fit: StackFit.expand, children: [
                  record.cover.isEmpty
                      ? Container(color: const Color(0xFFEDEDF0))
                      : CachedNetworkImage(
                          imageUrl: record.cover,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              Container(color: const Color(0xFFEDEDF0)),
                        ),
                  // 底部渐暗，衬托集数和进度条
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 44,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0x99000000)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    bottom: progress == null ? 6 : 9,
                    child: Text(
                      '第$episode集',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 3,
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.white.withValues(alpha: 0.28),
                        valueColor:
                            const AlwaysStoppedAnimation(Color(0xFFFF2442)),
                      ),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              record.dramaName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1D1D1F),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              count != null && count > 0
                  ? '看到第$episode集 · 共$count集'
                  : '看到第$episode集',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
            ),
          ],
        ),
      ),
    );
  }
}
