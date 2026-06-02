import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../models/episode.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/playback_history_store.dart';
import '../services/theater_video_preload_manager.dart';
import 'player_page.dart';

class DramaDetailPage extends StatefulWidget {
  const DramaDetailPage({
    super.key,
    required this.drama,
    required this.apiClient,
    this.downloadService,
  });

  final Drama drama;
  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  State<DramaDetailPage> createState() => _DramaDetailPageState();
}

class _DramaDetailPageState extends State<DramaDetailPage> {
  Drama? _detailDrama;
  bool _isLoading = true;
  int? _lastEpisodeIndex;
  int? _lastPositionMs;

  /// 进详情页就后台发起的剧集列表请求，进播放页时复用，省掉首集那次 App 接口往返。
  Future<TheaterEpisodesResult>? _prefetchedEpisodes;

  /// 详情页预热首集播放地址 + 512KB seed 用的预加载器。late 是因为要用 widget
  /// 的 apiClient 构造，在 initState 里初始化。
  late final TheaterVideoPreloadManager _detailPreloadManager =
      TheaterVideoPreloadManager(apiClient: widget.apiClient);

  Drama get drama => _detailDrama ?? widget.drama;
  ApiClient get apiClient => widget.apiClient;

  @override
  void initState() {
    super.initState();
    _loadDramaDetail();
    _loadHistory();
    _prefetchEpisodes();
  }

  // 用户在详情页看封面/简介的几秒里，把剧集列表先拉好。catchError 吞掉异常，
  // 让 Future 始终安全可 await —— 播放页拿到失败的 Future 会自行回退重新请求。
  // 列表到手后顺带预热首集播放地址 + 512KB seed，这样用户快速点进首集时大概率
  // 已命中 prewarm，cb_open 直接带解密数据出首帧，消除“没缓存好就进首集”的黑屏。
  void _prefetchEpisodes() {
    if (!widget.drama.isTheaterResource) return;
    final future = apiClient
        .fetchTheaterEpisodes(widget.drama.id.toString())
        .catchError((Object e) {
      debugPrint('详情页预取剧集列表失败(将由播放页回退): $e');
      throw e;
    });
    _prefetchedEpisodes = future;
    unawaited(_prewarmFirstEpisode(future));
  }

  // 预热首集：解析首集播放地址并触发 native 512KB prewarm。fire-and-forget，
  // 任何失败都只是退回“无预热”的冷路径，绝不影响详情页/播放页本身。
  Future<void> _prewarmFirstEpisode(
    Future<TheaterEpisodesResult> episodesFuture,
  ) async {
    try {
      final result = await episodesFuture;
      final episodes = result.chapters
          .map((c) => Episode(
                index: int.tryParse(c.realChapterOrder) ?? 0,
                name: c.title,
                size: 0,
                url: c.itemId,
              ))
          .toList();
      if (episodes.isEmpty) return;
      await _detailPreloadManager.preloadEpisode(
        episodes: episodes,
        currentIndex: 0,
        targetIndex: 0,
        isStillCurrent: () => mounted,
      );
    } catch (e) {
      debugPrint('详情页预热首集失败(将由播放页冷启动): $e');
    }
  }

  Future<void> _loadHistory() async {
    final records = await PlaybackHistoryStore.load();
    final record = records
        .where((r) => r.dramaId == widget.drama.id)
        .firstOrNull;
    if (record != null && mounted) {
      setState(() {
        _lastEpisodeIndex = record.episodeIndex;
        _lastPositionMs = record.positionMs;
      });
    }
  }

  Future<void> _loadDramaDetail() async {
    if (mounted) {
      setState(() {
        _detailDrama = widget.drama;
        _isLoading = false;
      });
    }
  }

  void _startPlay(BuildContext context, {bool resume = false}) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              drama: drama,
              apiClient: apiClient,
              downloadService: widget.downloadService,
              initialEpisodeIndex: resume ? _lastEpisodeIndex : null,
              initialPositionMs: resume ? _lastPositionMs : null,
              prefetchedEpisodes: _prefetchedEpisodes,
              preloadManager: _detailPreloadManager,
            ),
          ),
        )
        .then((_) async {
      // resolvePlayUrl 命中时 remove 掉了缓存项，返回详情页若不重新预热，再次
      // 播放就会 miss。这里 await 历史加载（拿到最新续播集）后重新预热首集，
      // 让“返回→再播放”同样秒开。
      await _loadHistory();
      final episodesFuture = _prefetchedEpisodes;
      if (episodesFuture != null) {
        unawaited(_prewarmFirstEpisode(episodesFuture));
      }
    });
  }

  Future<void> _downloadAll(BuildContext context) async {
    final ds = widget.downloadService;
    if (ds == null) return;
    try {
      final result = await apiClient.fetchTheaterEpisodes(drama.id.toString());
      final episodes = result.chapters
          .map(
            (c) => Episode(
              index: int.tryParse(c.realChapterOrder) ?? 0,
              name: c.title,
              size: 0,
              url: c.itemId,
            ),
          )
          .toList();
      if (episodes.isEmpty) {
        if (context.mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('暂无可下载的集数')));
        return;
      }
      await ds.addDownloads(
        dramaId: drama.id.toString(),
        dramaName: drama.name,
        episodes: episodes,
        coverUrl: drama.cover.isNotEmpty ? drama.cover : null,
        isTheaterResource: true,
        resolveUrl: (ep) async {
          final videoItems = await apiClient
              .fetchFqVideoModel(ep.url)
              .timeout(const Duration(seconds: 10));
          if (videoItems.isEmpty) throw Exception('未获取到视频信息');
          final selected = videoItems.firstWhere(
            (item) => item.definition == '1080p',
            orElse: () => videoItems.firstWhere(
              (item) => item.definition == '720p',
              orElse: () => videoItems.last,
            ),
          );
          final keyHex = await apiClient
              .fetchDecryptKey(selected.spadeA)
              .timeout(const Duration(seconds: 5));
          return DownloadResolveResult(cdnUrl: selected.url, keyHex: keyHex);
        },
      );
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已添加 ${episodes.length} 集到缓存队列')),
        );
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('获取集数失败，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 设置状态栏样式
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    final size = MediaQuery.of(context).size;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    // 加载中显示指示器
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CupertinoActivityIndicator(radius: 12)),
      );
    }

    // 加载失败或无数据（仅剧场资源需要加载详情）
    if (_detailDrama == null && widget.drama.isTheaterResource) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.black,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                '加载失败',
                style: TextStyle(color: Colors.grey[600], fontSize: 16),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                  });
                  _loadDramaDetail();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF2E55),
                  foregroundColor: Colors.white,
                ),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          _buildSliverAppBar(context, size),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, bottomPadding + 20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildHeaderInfo(context),
                const SizedBox(height: 24),
                _buildCastSection(context),
                const SizedBox(height: 16),
                _buildIntroSection(context),
                const SizedBox(height: 24),
                _buildActionButtons(context),
                const SizedBox(height: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliverAppBar(BuildContext context, Size size) {
    return SliverAppBar(
      expandedHeight: size.width * 0.9, // 缩小图片占比
      pinned: true,
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withOpacity(0.2),
              width: 0.5,
            ),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white,
            size: 18,
          ),
        ),
      ),
      actions: [
        GestureDetector(
          onTap: () {
            // TODO: Share implementation
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.2),
                width: 0.5,
              ),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.share_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: 'drama_cover_${drama.id}',
              child: drama.cover.isNotEmpty
                  ? Image.network(
                      drama.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildGradientBg(),
                    )
                  : _buildGradientBg(),
            ),
            // 全局渐变遮罩
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.2), // 顶部略微变暗
                      Colors.transparent,
                      Colors.white.withOpacity(0.3),
                      Colors.white.withOpacity(0.85),
                      Colors.white,
                    ],
                    stops: const [0.0, 0.25, 0.6, 0.85, 1.0],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderInfo(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          drama.name,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1D1D1F),
            height: 1.2,
            letterSpacing: -0.5,
          ),
        ),
        if (drama.subTitle != null && drama.subTitle!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            drama.subTitle!,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 16),
        // Meta Info
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (drama.score != null && drama.score!.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF0E0),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.star_rounded,
                      color: Colors.orange[700],
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      drama.score!,
                      style: TextStyle(
                        color: Colors.orange[800],
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              drama.pureCategoryTags ??
                  (drama.status.isNotEmpty ? drama.status : '热播中'),
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
            if (drama.recText != null && drama.recText!.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 1,
                    height: 10,
                    color: Colors.grey[300],
                    margin: const EdgeInsets.only(right: 8),
                  ),
                  const Icon(
                    Icons.whatshot_rounded,
                    color: Color(0xFFFF2E55),
                    size: 16,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    drama.recText!,
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            if (drama.status.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 1,
                    height: 10,
                    color: Colors.grey[300],
                    margin: const EdgeInsets.only(right: 8),
                  ),
                  Text(
                    drama.status,
                    style: TextStyle(color: Colors.grey[500], fontSize: 13),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF2E55).withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
              gradient: const LinearGradient(
                colors: [Color(0xFFFF2E55), Color(0xFFFF5656)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _startPlay(context),
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.play_circle_fill_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '立即播放',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.downloadService != null && drama.isTheaterResource) ...[
          const SizedBox(width: 12),
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFF2E55), width: 1.5),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _downloadAll(context),
                borderRadius: BorderRadius.circular(12),
                child: const Icon(
                  Icons.download_outlined,
                  color: Color(0xFFFF2E55),
                  size: 26,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCastSection(BuildContext context) {
    if (drama.role == null || drama.role!.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildInfoRow('角色', drama.role!),
        if (drama.createTime != null && drama.createTime!.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildInfoRow('更新', drama.createTime!),
        ],
      ],
    );
  }

  Widget _buildInfoRow(String label, String content) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        '$label: $content',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: Colors.grey[600],
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildIntroSection(BuildContext context) {
    if (drama.intro.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '剧情简介',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1D1D1F),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          drama.intro,
          style: const TextStyle(
            color: Color(0xFF424245),
            fontSize: 15,
            height: 1.6,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }

  Widget _buildGradientBg() {
    return Container(
      decoration: const BoxDecoration(color: Color(0xFFE5E5EA)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_rounded, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              '暂无封面',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
