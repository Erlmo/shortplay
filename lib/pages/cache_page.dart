import 'dart:io';

import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/offline_playback_cache.dart';
import 'player_page.dart';

class CachePage extends StatefulWidget {
  const CachePage({
    super.key,
    required this.downloadService,
    required this.apiClient,
  });
  final DownloadService downloadService;
  final ApiClient apiClient;

  @override
  State<CachePage> createState() => _CachePageState();
}

class _CachePageState extends State<CachePage> {
  @override
  void initState() {
    super.initState();
    widget.downloadService.addListener(_onChanged);
    if (!widget.downloadService.loaded) {
      widget.downloadService.ensureLoaded().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    widget.downloadService.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  void _playEpisode(DramaDownloadGroup group, EpisodeDownload ep) {
    final sortedEps = OfflinePlaybackCache.completedEpisodesFromGroup(group);
    final targetIndex = sortedEps.indexWhere(
      (e) => e.index == ep.episode.index,
    );
    if (targetIndex < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('本地缓存文件不存在，请重新下载'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final drama = Drama(
      id: int.tryParse(group.dramaId) ?? 0,
      name: group.dramaName,
      actors: '',
      cover: '',
      intro: '',
      tags: const [],
      status: '',
      updateTime: '',
      isTheaterResource: true,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          drama: drama,
          apiClient: widget.apiClient,
          downloadService: widget.downloadService,
          initialEpisodeIndex: targetIndex,
          initialEpisodeNumber: ep.episode.index,
          offlineEpisodes: sortedEps,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = widget.downloadService;

    // 等待加载完成
    if (!ds.loaded) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: const Text(
            '缓存',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1D1D1F),
            ),
          ),
          centerTitle: false,
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final groups = ds.groups.values.toList();

    return Scaffold(
      backgroundColor: Colors.white,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            title: const Text(
              '缓存',
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
          ),
          if (groups.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 100),
                child: Column(
                  children: [
                    Icon(
                      Icons.download_rounded,
                      size: 80,
                      color: Colors.grey[200],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '暂无缓存',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '在播放页点击下载按钮即可缓存剧集',
                      style: TextStyle(color: Colors.grey[300], fontSize: 13),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _GroupCard(
                  group: groups[i],
                  onDelete: () => _confirmDelete(context, groups[i]),
                  onPlay: (ep) => _playEpisode(groups[i], ep),
                  downloadService: widget.downloadService,
                ),
                childCount: groups.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, DramaDownloadGroup group) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除缓存'),
        content: Text('确定删除《${group.dramaName}》的所有缓存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.downloadService.deleteGroup(group.dramaId);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({
    required this.group,
    required this.onDelete,
    required this.onPlay,
    required this.downloadService,
  });
  final DramaDownloadGroup group;
  final VoidCallback onDelete;
  final void Function(EpisodeDownload) onPlay;
  final DownloadService downloadService;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final sortedEps = group.episodes.toList()
      ..sort((a, b) => a.episode.index.compareTo(b.episode.index));
    final isPaused = widget.downloadService.isGroupPaused(group.dramaId);
    final progress =
        group.totalCount > 0 ? group.completedCount / group.totalCount : 0.0;

    return Dismissible(
      key: ValueKey(group.dramaId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: const Color(0xFFFF2442),
        child: const Icon(
          Icons.delete_forever_rounded,
          color: Colors.white,
          size: 26,
        ),
      ),
      onDismissed: (_) => widget.onDelete(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 72,
                      height: 96,
                      child: group.localCoverPath != null
                          ? Image.file(
                              File(group.localCoverPath!),
                              fit: BoxFit.cover,
                            )
                          : Container(
                              color: const Color(0xFFF0F0F0),
                              child: const Icon(
                                Icons.movie_outlined,
                                color: Color(0xFFCCCCCC),
                                size: 28,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 96,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    group.dramaName,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1D1D1F),
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () =>
                                      setState(() => _expanded = !_expanded),
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Icon(
                                      _expanded
                                          ? Icons.keyboard_arrow_up_rounded
                                          : Icons.keyboard_arrow_down_rounded,
                                      size: 20,
                                      color: const Color(0xFFCCCCCC),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                group.isAllCompleted
                                    ? '共 ${group.completedCount} 集'
                                    : '已缓存 ${group.completedCount} / ${group.totalCount} 集',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF999999),
                                ),
                              ),
                              if (!group.isAllCompleted) ...[
                                const Spacer(),
                                Text(
                                  '${(progress * 100).toInt()}%',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFFFF2442),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (group.isAllCompleted)
                            const Text(
                              '已完成',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF34C759),
                                fontWeight: FontWeight.w500,
                              ),
                            )
                          else
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => isPaused
                                  ? widget.downloadService.resumeGroup(
                                      group.dramaId,
                                    )
                                  : widget.downloadService.pauseGroup(
                                      group.dramaId,
                                    ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFF2442),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        isPaused
                                            ? Icons.play_arrow_rounded
                                            : Icons.pause_rounded,
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isPaused ? '继续下载' : '暂停下载',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF333333),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: sortedEps
                    .map(
                      (ep) => _EpisodeChip(
                        ep: ep,
                        downloadService: widget.downloadService,
                        onPlay: ep.status == DownloadStatus.completed
                            ? () => widget.onPlay(ep)
                            : null,
                      ),
                    )
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}

class _EpisodeChip extends StatelessWidget {
  const _EpisodeChip({
    required this.ep,
    required this.downloadService,
    this.onPlay,
  });
  final EpisodeDownload ep;
  final DownloadService downloadService;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final status = ep.status;
    final isCompleted = status == DownloadStatus.completed;
    final isDownloading = status == DownloadStatus.downloading;
    final isPaused = status == DownloadStatus.paused;
    final isPending = status == DownloadStatus.pending;

    Color bgColor;
    Color textColor;
    if (isCompleted) {
      bgColor = Colors.white;
      textColor = const Color(0xFF1D1D1F);
    } else if (isDownloading) {
      bgColor = const Color(0xFFFF2442).withValues(alpha: 0.08);
      textColor = const Color(0xFFFF2442);
    } else if (isPaused) {
      bgColor = const Color(0xFFFFF3E0);
      textColor = const Color(0xFFFF9800);
    } else {
      bgColor = const Color(0xFFEEEEEE);
      textColor = const Color(0xFF999999);
    }

    return GestureDetector(
      onTap: () {
        if (isCompleted) {
          onPlay?.call();
        } else if (isDownloading) {
          downloadService.pauseEpisode(ep);
        } else if (isPaused) {
          downloadService.resumeEpisode(ep);
        } else if (status == DownloadStatus.failed) {
          ep.status = DownloadStatus.paused;
          downloadService.resumeEpisode(ep);
        }
      },
      child: Container(
        width: 56,
        height: 36,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCompleted
                ? const Color(0xFFFF2442).withValues(alpha: 0.3)
                : Colors.transparent,
          ),
        ),
        child: isDownloading
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 32,
                    child: LinearProgressIndicator(
                      value: ep.progress < 0 ? null : ep.progress,
                      minHeight: 2,
                      color: const Color(0xFFFF2442),
                      backgroundColor: Colors.grey[200],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ep.progress < 0 ? '下载中' : '${(ep.progress * 100).toInt()}%',
                    style: const TextStyle(
                      fontSize: 9,
                      color: Color(0xFFFF2442),
                    ),
                  ),
                ],
              )
            : Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    '第${ep.episode.index}集',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  if (isPaused)
                    const Positioned(
                      right: 3,
                      top: 3,
                      child: Icon(
                        Icons.pause_circle_outline,
                        size: 10,
                        color: Color(0xFFFF9800),
                      ),
                    ),
                  if (status == DownloadStatus.failed)
                    const Positioned(
                      right: 3,
                      top: 3,
                      child: Icon(
                        Icons.error_outline,
                        size: 10,
                        color: Colors.red,
                      ),
                    ),
                  if (isPending)
                    const Positioned(
                      right: 3,
                      top: 3,
                      child: Icon(
                        Icons.schedule,
                        size: 10,
                        color: Color(0xFF999999),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
