import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../services/api_client.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../services/offline_playback_cache.dart';
import '../widgets/app_notice.dart';
import '../widgets/tv_tap.dart';
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

class _CachePageState extends State<CachePage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    widget.downloadService.addListener(_onChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshFiles());
  }

  @override
  void dispose() {
    widget.downloadService.removeListener(_onChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshFiles());
  }

  Future<void> _refreshFiles() async {
    try {
      await widget.downloadService.refreshFiles();
    } catch (error) {
      debugPrint('刷新缓存失败: $error');
    }
  }

  Future<void> _deleteGroup(DramaDownloadGroup group) async {
    try {
      await widget.downloadService.deleteGroup(group.dramaId);
    } catch (error) {
      if (mounted) {
        showAppNotice(context,
            message: '删除缓存失败',
            detail: error is ApiException ? error.message : '请稍后重试',
            kind: AppNoticeKind.error);
      }
    }
  }

  void _playEpisode(DramaDownloadGroup group, EpisodeDownload ep) {
    final sortedEps = OfflinePlaybackCache.completedEpisodesFromGroup(group);
    final targetIndex = sortedEps.indexWhere(
      (e) => e.index == ep.episode.index,
    );
    if (targetIndex < 0) {
      unawaited(_refreshFiles());
      showAppNotice(context,
          message: '本地缓存不可用', detail: '文件已丢失，请重新下载', kind: AppNoticeKind.error);
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

  // 全部暂停 / 全部开始（红果下载页 DownloadingHeader）
  void _toggleAll(List<DramaDownloadGroup> unfinished, bool anyRunning) {
    final ds = widget.downloadService;
    for (final g in unfinished) {
      if (anyRunning) {
        if (!ds.isGroupPaused(g.dramaId)) ds.pauseGroup(g.dramaId);
      } else {
        if (ds.isGroupPaused(g.dramaId)) ds.resumeGroup(g.dramaId);
      }
    }
  }

  PreferredSizeWidget _appBar() => AppBar(
        title: const Text(
          '缓存',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: _Hg.black,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: _Hg.black,
      );

  @override
  Widget build(BuildContext context) {
    final ds = widget.downloadService;

    // 等待加载完成
    if (!ds.loaded) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: _appBar(),
        body: const Center(
            child: CircularProgressIndicator(color: _Hg.brand, strokeWidth: 2)),
      );
    }

    final groups = ds.groups.values.toList();
    final unfinished = groups.where((g) => !g.isAllCompleted).toList();
    final anyRunning = unfinished.any((g) => !ds.isGroupPaused(g.dramaId));

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _appBar(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          if (ds.lastError != null)
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                decoration: BoxDecoration(
                  color: const Color(0x0FF54A45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.error_outline_rounded,
                      color: _Hg.red, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(ds.lastError!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _Hg.red, fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: _refreshFiles,
                    style: TextButton.styleFrom(foregroundColor: _Hg.red),
                    child: const Text('重试', style: TextStyle(fontSize: 12)),
                  ),
                ]),
              ),
            ),
          if (groups.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 80),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                          color: _Hg.fill, shape: BoxShape.circle),
                      child: const Icon(Icons.download_rounded,
                          size: 30, color: _Hg.gray40),
                    ),
                    const SizedBox(height: 16),
                    const Text('暂无缓存',
                        style: TextStyle(
                            color: _Hg.gray70,
                            fontSize: 15,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 6),
                    const Text('在播放页右上角「…」或详情页找到下载入口',
                        style: TextStyle(color: _Hg.gray40, fontSize: 13)),
                  ],
                ),
              ),
            )
          else ...[
            // 红果下载页头部：左侧“共N个”，右侧“全部暂停/全部开始”
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Row(children: [
                  Text('共${groups.length}个',
                      style: const TextStyle(color: _Hg.gray40, fontSize: 12)),
                  const Spacer(),
                  if (unfinished.isNotEmpty)
                    TvTap(
                      borderRadius: 18,
                      onTap: () => _toggleAll(unfinished, anyRunning),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0x0A000000),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(anyRunning ? '全部暂停' : '全部开始',
                            style: const TextStyle(
                                color: Color(0xBF000000), fontSize: 12)),
                      ),
                    ),
                ]),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _GroupCard(
                  key: ValueKey(groups[i].dramaId),
                  group: groups[i],
                  onDelete: () => _confirmDelete(context, groups[i]),
                  onPlay: (ep) => _playEpisode(groups[i], ep),
                  downloadService: widget.downloadService,
                ),
                childCount: groups.length,
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }

  /// 弹确认框；确认后删除。返回是否已确认（左滑删除据此决定是否把这一行滑走）。
  Future<bool> _confirmDelete(
      BuildContext context, DramaDownloadGroup group) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('删除缓存',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _Hg.black)),
        content: Text('确定删除《${group.dramaName}》的所有缓存？',
            style: const TextStyle(fontSize: 14, color: _Hg.gray70)),
        actions: [
          TextButton(
            autofocus: DeviceProfile.usesFocusUi,
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: _Hg.gray70),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: _Hg.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    unawaited(_deleteGroup(group));
    return true;
  }
}

/// 红果浅色配色（skin_color_*_light）与品牌橙
class _Hg {
  static const black = Color(0xFF000000);
  static const gray70 = Color(0xB2000000);
  static const gray40 = Color(0x66000000);
  static const fill = Color(0x08000000);
  static const brand = Color(0xFFFA6725);
  static const brandBg = Color(0x1AFA6725);
  static const red = Color(0xFFF54A45);
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({
    super.key,
    required this.group,
    required this.onDelete,
    required this.onPlay,
    required this.downloadService,
  });
  final DramaDownloadGroup group;
  final Future<bool> Function() onDelete;
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
    final done = group.isAllCompleted;
    final progress =
        group.totalCount > 0 ? group.completedCount / group.totalCount : 0.0;

    // 状态文字：下载中 xx% / 已暂停 / N集失败
    String statusText;
    Color statusColor;
    if (group.failedCount > 0) {
      statusText = '${group.failedCount}集失败';
      statusColor = _Hg.red;
    } else if (isPaused) {
      statusText = '已暂停 · ${(progress * 100).toInt()}%';
      statusColor = _Hg.gray40;
    } else {
      statusText = '下载中 · ${(progress * 100).toInt()}%';
      statusColor = _Hg.brand;
    }

    return Dismissible(
      key: ValueKey(group.dramaId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: _Hg.red,
        child: const Text('删除',
            style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500)),
      ),
      // 先确认再滑走：不滑走时 Dismissible 会回弹，确认后由删除结果把这一行移出列表
      confirmDismiss: (_) async {
        await widget.onDelete();
        return false;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            // 电视把焦点交给独立操作按钮，避免整行覆盖内部按钮的导航区域。
            canRequestFocus: !DeviceProfile.usesFocusUi,
            onTap: () => setState(() => _expanded = !_expanded),
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 70,
                      height: 98,
                      child: group.localCoverPath != null
                          ? Image.file(
                              File(group.localCoverPath!),
                              fit: BoxFit.cover,
                            )
                          : Container(
                              color: _Hg.fill,
                              child: const Icon(Icons.movie_outlined,
                                  color: _Hg.gray40, size: 26),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.dramaName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: _Hg.black,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          done
                              ? '已下载${group.completedCount}集'
                              : '共${group.totalCount}集 · 已下载${group.completedCount}集',
                          style:
                              const TextStyle(fontSize: 12, color: _Hg.gray40),
                        ),
                        if (!done) ...[
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(1),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 2,
                              color: isPaused ? _Hg.gray40 : _Hg.brand,
                              backgroundColor: const Color(0x0F000000),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(statusText,
                              style:
                                  TextStyle(fontSize: 12, color: statusColor)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!done)
                    _CacheAction(
                      label: isPaused ? '继续缓存' : '暂停缓存',
                      icon: isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded,
                      onTap: () => isPaused
                          ? widget.downloadService.resumeGroup(group.dramaId)
                          : widget.downloadService.pauseGroup(group.dramaId),
                    ),
                  _CacheAction(
                    label: _expanded ? '收起集数' : '展开集数',
                    compact: true,
                    icon: _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    onTap: () => setState(() => _expanded = !_expanded),
                  ),
                  if (DeviceProfile.usesFocusUi)
                    _CacheAction(
                      label: '删除缓存',
                      icon: Icons.delete_outline_rounded,
                      onTap: () => widget.onDelete(),
                    ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: sortedEps
                    .map(
                      (ep) => _EpisodeChip(
                        ep: ep,
                        downloadService: widget.downloadService,
                        onPlay: ep.isPlayable ? () => widget.onPlay(ep) : null,
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

/// 组操作独立聚焦，方向键可以依次选中暂停、展开和删除。
class _CacheAction extends StatelessWidget {
  const _CacheAction(
      {required this.label,
      required this.icon,
      required this.onTap,
      this.compact = false});

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final focusUi = DeviceProfile.usesFocusUi;
    return Padding(
      padding: EdgeInsets.only(left: focusUi ? 8 : 4),
      child: Semantics(
        button: true,
        label: label,
        child: TvTap(
          borderRadius: focusUi ? 12 : 16,
          focusScale: 1,
          onTap: onTap,
          child: Tooltip(
            message: label,
            child: Container(
              width: focusUi
                  ? 44
                  : compact
                      ? 20
                      : 32,
              height: focusUi
                  ? 44
                  : compact
                      ? 20
                      : 32,
              decoration: BoxDecoration(
                  color: compact && !focusUi ? Colors.transparent : _Hg.fill,
                  borderRadius: BorderRadius.circular(focusUi ? 12 : 16)),
              child: Icon(icon,
                  size: focusUi || compact ? 20 : 18, color: _Hg.gray70),
            ),
          ),
        ),
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
    final isCompleted = ep.isPlayable;
    final isDownloading = status == DownloadStatus.downloading;
    final isPaused = status == DownloadStatus.paused;
    final isPending = status == DownloadStatus.pending;
    final isFailed = status == DownloadStatus.failed;

    Color bgColor;
    Color textColor;
    if (isCompleted) {
      bgColor = _Hg.fill;
      textColor = _Hg.black;
    } else if (isDownloading) {
      bgColor = _Hg.brandBg;
      textColor = _Hg.brand;
    } else if (isFailed) {
      bgColor = const Color(0x0FF54A45);
      textColor = _Hg.red;
    } else {
      bgColor = _Hg.fill;
      textColor = _Hg.gray40;
    }

    return GestureDetector(
      onLongPress: ep.error == null
          ? null
          : () {
              showAppNotice(context,
                  message: '第${ep.episode.index}集缓存失败',
                  detail: ep.error!,
                  kind: AppNoticeKind.error);
            },
      child: Semantics(
        button: true,
        label:
            '第${ep.episode.index}集，${isCompleted ? '播放已缓存剧集' : isDownloading || isPending ? '暂停缓存' : '开始缓存'}',
        child: TvTap(
          borderRadius: 6,
          focusScale: 1,
          onTap: () {
            if (isCompleted) {
              onPlay?.call();
            } else if (isDownloading || isPending) {
              downloadService.pauseEpisode(ep);
            } else if (isPaused) {
              downloadService.resumeEpisode(ep);
            } else if (status == DownloadStatus.failed ||
                status == DownloadStatus.completed) {
              downloadService.resumeEpisode(ep);
            }
          },
          child: Container(
            width: 56,
            height: 36,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: isDownloading
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        ep.progress < 0
                            ? '下载中'
                            : '${(ep.progress * 100).toInt()}%',
                        style: const TextStyle(fontSize: 11, color: _Hg.brand),
                      ),
                      const SizedBox(height: 3),
                      SizedBox(
                        width: 32,
                        child: LinearProgressIndicator(
                          value: ep.progress < 0 ? null : ep.progress,
                          minHeight: 2,
                          color: _Hg.brand,
                          backgroundColor: const Color(0x1AFA6725),
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
                          fontWeight:
                              isCompleted ? FontWeight.w500 : FontWeight.w400,
                          color: textColor,
                        ),
                      ),
                      if (isPaused)
                        const Positioned(
                          right: 3,
                          top: 3,
                          child: Icon(Icons.pause_rounded,
                              size: 10, color: _Hg.gray40),
                        ),
                      if (isFailed)
                        const Positioned(
                          right: 3,
                          top: 3,
                          child: Icon(Icons.error_outline_rounded,
                              size: 10, color: _Hg.red),
                        ),
                      if (isPending)
                        const Positioned(
                          right: 3,
                          top: 3,
                          child: Icon(Icons.schedule_rounded,
                              size: 10, color: _Hg.gray40),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
