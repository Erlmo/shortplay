import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../models/episode.dart';
import '../models/playback_record.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/offline_playback_cache.dart';
import '../services/playback_history_store.dart';
import 'player_page.dart';

class PlayHistoryPage extends StatefulWidget {
  const PlayHistoryPage({
    super.key,
    required this.apiClient,
    this.downloadService,
  });

  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  State<PlayHistoryPage> createState() => PlayHistoryPageState();
}

class PlayHistoryPageState extends State<PlayHistoryPage> {
  // Use a heterogeneous list for headers and items
  List<Object> _displayItems = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rawItems = await PlaybackHistoryStore.load();
    if (!mounted) return;

    final grouped = _groupItems(rawItems);

    setState(() {
      _displayItems = grouped;
      _loading = false;
    });
  }

  // 公共方法：供外部调用刷新数据（比如tab切换时）
  void refresh() {
    _load();
  }

  // Group items by simple date buckets
  List<Object> _groupItems(List<PlaybackRecord> records) {
    if (records.isEmpty) return [];

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final List<Object> result = [];

    // Sort by update time desc just in case
    records.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));

    String? currentHeader;

    for (var record in records) {
      final date = DateTime.fromMillisecondsSinceEpoch(record.updatedAtMs);
      final dateOnly = DateTime(date.year, date.month, date.day);

      String header;
      if (dateOnly.isAtSameMomentAs(today)) {
        header = '今天';
      } else if (dateOnly.isAtSameMomentAs(yesterday)) {
        header = '昨天';
      } else {
        header = '更早以前';
      }

      if (header != currentHeader) {
        result.add(_HeaderItem(header));
        currentHeader = header;
      }
      result.add(record);
    }

    return result;
  }

  Future<void> _clearAll() async {
    await PlaybackHistoryStore.clear();
    await _load();
  }

  void _openRecord(PlaybackRecord record) {
    final drama = Drama(
      id: record.dramaId,
      name: record.dramaName,
      actors: '',
      cover: record.cover,
      intro: '',
      tags: const [],
      status: '',
      updateTime: '',
      isTheaterResource: record.dramaId != 0,
    );

    // 检查是否有本地缓存
    final ds = widget.downloadService;
    List<Episode>? offlineEpisodes;
    if (ds != null) {
      final group = ds.groups[record.dramaId.toString()];
      if (group != null) {
        final completed = OfflinePlaybackCache.completedEpisodesFromGroup(
          group,
        );
        if (completed.isNotEmpty) offlineEpisodes = completed;
      }
    }

    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              drama: drama,
              apiClient: widget.apiClient,
              downloadService: ds,
              initialEpisodeIndex: record.episodeIndex,
              initialEpisodeNumber: record.episodeNumber,
              initialPositionMs: record.positionMs,
              offlineEpisodes: offlineEpisodes,
            ),
          ),
        )
        .then((_) => _load());
  }

  String _formatMs(int ms) {
    if (ms <= 0) return '00:00';
    final totalSeconds = (ms / 1000).floor();
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverAppBar(
                  title: const Text(
                    '播放记录',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1D1D1F),
                    ),
                  ),
                  centerTitle: false,
                  pinned: true,
                  backgroundColor: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  foregroundColor: const Color(0xFF1D1D1F),
                  actions: [
                    if (_displayItems.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 16.0),
                        child: TextButton(
                          onPressed: _clearAll,
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF999999),
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          child: const Text('清空'),
                        ),
                      ),
                  ],
                ),
                if (_displayItems.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 100),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.history_edu_rounded,
                            size: 80,
                            color: Colors.grey[200],
                          ),
                          const SizedBox(height: 24),
                          Text(
                            '暂无播放记录',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final item = _displayItems[index];

                      if (item is _HeaderItem) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                          child: Text(
                            item.title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1D1D1F),
                            ),
                          ),
                        );
                      }

                      if (item is PlaybackRecord) {
                        return _buildRecordItem(item);
                      }

                      return const SizedBox.shrink();
                    }, childCount: _displayItems.length),
                  ),

                // Bottom padding
                const SliverToBoxAdapter(child: SizedBox(height: 48)),
              ],
            ),
    );
  }

  Widget _buildRecordItem(PlaybackRecord record) {
    final defaultCover = Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFE3F2FD), Color(0xFF90CAF9)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.folder_shared_rounded,
          color: Color(0xFF1E88E5),
          size: 28,
        ),
      ),
    );

    return Dismissible(
      key: ValueKey('${record.dramaId}_${record.episodeIndex}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: const Color(0xFFFF2442),
        child: const Icon(
          Icons.delete_forever_rounded,
          color: Colors.white,
          size: 28,
        ),
      ),
      onDismissed: (_) {
        // 立即从显示列表中移除该record，避免"dismissed widget still in tree"错误
        setState(() {
          final recordIndex = _displayItems.indexOf(record);
          if (recordIndex != -1) {
            _displayItems.removeAt(recordIndex);

            // 检查是否需要移除对应的header（如果该header下没有其他record了）
            if (recordIndex > 0 &&
                _displayItems[recordIndex - 1] is _HeaderItem) {
              final headerIndex = recordIndex - 1;
              // 检查header后面是否还有record（不是另一个header或列表末尾）
              if (recordIndex >= _displayItems.length ||
                  _displayItems[recordIndex] is _HeaderItem) {
                _displayItems.removeAt(headerIndex);
              }
            }
          }
        });

        // 异步删除持久化数据
        PlaybackHistoryStore.removeByKey(record.dramaId);
      },
      child: InkWell(
        onTap: () => _openRecord(record),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Thumbnail (Horizontal 16:9)
              Container(
                width: 110,
                height: 62,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.circular(6),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    record.cover.trim().isEmpty
                        ? defaultCover
                        : Image.network(
                            record.cover,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => defaultCover,
                          ),
                    // Optional: Darken overly
                    Container(color: Colors.black.withOpacity(0.05)),
                    // Center Play Icon (Small)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.3),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      record.dramaName.isEmpty ? '未命名短剧' : record.dramaName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF333333),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF0F0),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            '第${record.episodeIndex + 1}集',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFFFF2442),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '看到 ${_formatMs(record.positionMs)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderItem {
  final String title;
  const _HeaderItem(this.title);
}
