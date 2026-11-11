import 'package:flutter/material.dart';

import '../models/playback_record.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/playback_history_store.dart';
import '../widgets/app_notice.dart';
import '../widgets/tv_tap.dart';
import 'playback_record_launcher.dart';

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
  bool _managing = false;
  bool _deleting = false;
  int _loadRevision = 0;
  final Set<String> _selected = {};

  Iterable<PlaybackRecord> get _records =>
      _displayItems.whereType<PlaybackRecord>();

  void _toggleRecord(PlaybackRecord record) {
    if (_deleting) return;
    final key = PlaybackHistoryStore.recordKey(record);
    setState(() {
      if (!_selected.add(key)) _selected.remove(key);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _deleting) return;
    setState(() => _deleting = true);
    try {
      await PlaybackHistoryStore.removeRecords(_selected);
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _managing = false;
      });
      await _load(silent: true);
    } catch (_) {
      if (mounted) {
        showAppNotice(context, message: '删除失败，请重试', kind: AppNoticeKind.error);
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    PlaybackHistoryStore.revision.addListener(_onHistoryChanged);
  }

  @override
  void dispose() {
    PlaybackHistoryStore.revision.removeListener(_onHistoryChanged);
    super.dispose();
  }

  // 播放页退出 / 定时保存进度后静默刷新，不闪加载圈。
  void _onHistoryChanged() => _load(silent: true);

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final revision = ++_loadRevision;
    final rawItems = await PlaybackHistoryStore.load();
    if (!mounted || revision != _loadRevision) return;

    final grouped = _groupItems(rawItems);

    setState(() {
      _displayItems = grouped;
      _selected.retainAll(rawItems.map(PlaybackHistoryStore.recordKey));
      if (rawItems.isEmpty) _managing = false;
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
    if (_deleting) return;
    setState(() => _deleting = true);
    try {
      await PlaybackHistoryStore.clear();
      if (mounted) await _load(silent: true);
    } catch (_) {
      if (mounted) {
        showAppNotice(context, message: '清空失败，请重试', kind: AppNoticeKind.error);
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  void _openRecord(PlaybackRecord record) {
    openPlaybackRecord(
      context,
      record: record,
      apiClient: widget.apiClient,
      downloadService: widget.downloadService,
    ).then((_) => _load());
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
      bottomNavigationBar: !_managing
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Row(children: [
                  TextButton(
                      onPressed: _deleting
                          ? null
                          : () => setState(() {
                                final keys = _records
                                    .map(PlaybackHistoryStore.recordKey)
                                    .toSet();
                                if (_selected.length == keys.length) {
                                  _selected.clear();
                                } else {
                                  _selected.addAll(keys);
                                }
                              }),
                      child: Text(
                          _selected.length == _records.length ? '取消全选' : '全选')),
                  const Spacer(),
                  Text('已选 ${_selected.length} 条'),
                  const SizedBox(width: 16),
                  FilledButton(
                      onPressed: _selected.isEmpty || _deleting
                          ? null
                          : _deleteSelected,
                      child: Text(_deleting ? '删除中…' : '删除')),
                ]),
              )),
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
                      TextButton(
                          onPressed: _deleting
                              ? null
                              : () => setState(() {
                                    _managing = !_managing;
                                    _selected.clear();
                                  }),
                          child: Text(_managing ? '完成' : '管理')),
                    if (_displayItems.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 16.0),
                        child: TextButton(
                          onPressed: _deleting ? null : _clearAll,
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
      key: ValueKey(PlaybackHistoryStore.recordKey(record)),
      direction: _managing || _deleting
          ? DismissDirection.none
          : DismissDirection.endToStart,
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
        PlaybackHistoryStore.removeRecords(
                [PlaybackHistoryStore.recordKey(record)])
            .catchError((Object error) {
          if (mounted) {
            _load(silent: true);
            showAppNotice(context,
                message: '删除失败，请重试', kind: AppNoticeKind.error);
          }
        });
      },
      child: TvTap(
        ink: true,
        borderRadius: 0,
        focusScale: 1.0,
        onTap: () => _managing ? _toggleRecord(record) : _openRecord(record),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (_managing)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(
                      _selected.contains(PlaybackHistoryStore.recordKey(record))
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: _selected
                              .contains(PlaybackHistoryStore.recordKey(record))
                          ? const Color(0xFFFF2442)
                          : Colors.grey,
                      semanticLabel: _selected
                              .contains(PlaybackHistoryStore.recordKey(record))
                          ? '已选择'
                          : '未选择'),
                ),
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
                    Container(color: Colors.black.withValues(alpha: 0.05)),
                    // Center Play Icon (Small)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.3),
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
