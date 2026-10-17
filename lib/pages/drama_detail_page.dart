import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../models/drama_season.dart';
import '../models/episode.dart';
import '../services/api_client.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../services/playback_history_store.dart';
import '../services/theater_video_preload_manager.dart';
import '../widgets/app_notice.dart';
import '../widgets/detail_action_bar.dart';
import '../widgets/detail_episode_strip.dart';
import '../widgets/episode_selector.dart';
import '../widgets/expandable_synopsis.dart';
import '../widgets/related_seasons.dart';
import '../widgets/tv_drama_detail_view.dart';
import '../widgets/tv_tap.dart';
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
  bool _addingDownloads = false;
  int? _lastEpisodeIndex;
  int? _lastPositionMs;
  final CancelToken _seasonsCancelToken = CancelToken();
  DramaSeasons? _seasons;
  bool _loadingSeasons = false;
  bool _seasonsFailed = false;

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
    if (widget.drama.isTheaterResource) unawaited(_loadSeasons());
  }

  @override
  void dispose() {
    _seasonsCancelToken.cancel('详情页已关闭');
    super.dispose();
  }

  Future<void> _loadSeasons() async {
    if (_loadingSeasons) return;
    setState(() {
      _loadingSeasons = true;
      _seasonsFailed = false;
    });
    try {
      final seasons = await apiClient.fetchDramaSeasons(
          widget.drama.id.toString(),
          cancelToken: _seasonsCancelToken);
      if (mounted) setState(() => _seasons = seasons);
    } catch (_) {
      if (mounted) setState(() => _seasonsFailed = true);
    } finally {
      if (mounted) setState(() => _loadingSeasons = false);
    }
  }

  void _openSeason(DramaSeason season) {
    if (season.id == drama.id) return;
    setState(() {
      _detailDrama = season.toDrama();
      _lastEpisodeIndex = null;
      _lastPositionMs = null;
      _detailPreloadManager.clear();
      _prefetchEpisodes();
    });
    unawaited(_loadHistory());
  }

  Widget? _buildSeasonSelector() {
    if (_loadingSeasons) {
      return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('正在查找其他季…', style: TextStyle(color: Color(0xFF9299A6))));
    }
    if (_seasonsFailed) {
      return Row(children: [
        const Expanded(
            child: Text('其他季暂时加载失败',
                style: TextStyle(color: Color(0xFF9299A6), fontSize: 13))),
        TextButton(onPressed: _loadSeasons, child: const Text('重试')),
      ]);
    }
    final seasons = _seasons?.seasons;
    if (seasons == null ||
        seasons.length < 2 ||
        !seasons.any((s) => s.id != drama.id)) {
      return null;
    }
    return RelatedSeasons(
        seasons: seasons, currentId: drama.id, onSelect: _openSeason);
  }

  // 用户在详情页看封面/简介的几秒里，把剧集列表先拉好。catchError 吞掉异常，
  // 让 Future 始终安全可 await —— 播放页拿到失败的 Future 会自行回退重新请求。
  // 列表到手后顺带预热首集播放地址 + 512KB seed，这样用户快速点进首集时大概率
  // 已命中 prewarm，cb_open 直接带解密数据出首帧，消除“没缓存好就进首集”的黑屏。
  void _prefetchEpisodes() {
    if (!drama.isTheaterResource) return;
    final requestedId = drama.id;
    final future =
        apiClient.fetchTheaterEpisodes(requestedId.toString()).then((result) {
      // 切换季时先展示关联卡片的信息，再用该季目录补全简介等详情。
      if (mounted &&
          result.bookInfo != null &&
          requestedId == drama.id &&
          result.bookInfo!.id == requestedId) {
        setState(() => _detailDrama = result.bookInfo);
      }
      return result;
    }).catchError((Object e) {
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
      if (!mounted || !identical(episodesFuture, _prefetchedEpisodes)) return;
      final episodes = result.toEpisodes();
      if (episodes.isEmpty) return;
      await _detailPreloadManager.preloadEpisode(
        episodes: episodes,
        currentIndex: 0,
        targetIndex: 0,
        isStillCurrent: () =>
            mounted && identical(episodesFuture, _prefetchedEpisodes),
      );
    } catch (e) {
      debugPrint('详情页预热首集失败(将由播放页冷启动): $e');
    }
  }

  Future<void> _loadHistory() async {
    final requestedId = drama.id;
    final records = await PlaybackHistoryStore.load();
    if (!mounted || drama.id != requestedId) return;
    final record = records.where((r) => r.dramaId == requestedId).firstOrNull;
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

  void _startPlay(BuildContext context,
      {bool resume = false, int? episodeIndex}) {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          drama: drama,
          apiClient: apiClient,
          downloadService: widget.downloadService,
          initialEpisodeIndex:
              episodeIndex ?? (resume ? (_lastEpisodeIndex ?? 0) : 0),
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
    if (ds == null || _addingDownloads) return;
    final targetDrama = drama;
    setState(() => _addingDownloads = true);
    try {
      final result =
          await apiClient.fetchTheaterEpisodes(targetDrama.id.toString());
      final queued = await ds.addDownloads(
        dramaId: targetDrama.id.toString(),
        dramaName: targetDrama.name,
        episodes: result.toEpisodes(),
        coverUrl: targetDrama.cover.isNotEmpty ? targetDrama.cover : null,
        isTheaterResource: true,
      );
      if (context.mounted) {
        showAppNotice(context,
            message: queued > 0 ? '缓存任务已添加' : '无需重复下载',
            detail: queued > 0 ? '已加入 $queued 集，可在缓存页查看进度' : '这些剧集已缓存或正在下载',
            kind: queued > 0 ? AppNoticeKind.success : AppNoticeKind.info);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              error is ApiException ? error.message : '添加缓存失败，请检查网络或存储空间后重试'),
        ));
      }
    } finally {
      if (mounted) setState(() => _addingDownloads = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 设置状态栏样式
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    final size = MediaQuery.of(context).size;

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

    if (DeviceProfile.usesFocusUi && size.width > size.height) {
      return _buildWideLayout(context);
    }

    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: _buildImmersiveActions(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        cacheExtent: DeviceProfile.usesFocusUi ? 3000 : null,
        slivers: [
          _buildSliverAppBar(context, size),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList(
                delegate: SliverChildListDelegate([
              _buildImmersiveHeader(),
              if (drama.intro.isNotEmpty) ...[
                const SizedBox(height: 8),
                ExpandableSynopsis(
                    key: ValueKey('synopsis-${drama.id}'),
                    text: drama.intro,
                    showHeading: false,
                    initiallyExpanded: true),
              ],
              if (_prefetchedEpisodes != null) ...[
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1, color: Color(0xFFF3F4F6))),
                _buildCompactEpisodes(),
              ],
            ])),
          ),
        ],
      ),
    );
  }

  Widget _buildImmersiveHeader() {
    final suffix = RegExp(r'第[一二三四五六七八九十百零两0-9]+季$').firstMatch(drama.name);
    final title = suffix == null || suffix.start == 0
        ? drama.name
        : drama.name.substring(0, suffix.start).trim();
    final tags = <String>{
      ...(drama.pureCategoryTags ?? '').split(RegExp(r'[,，·]')),
      ...drama.tags,
    }.map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).take(3);
    final metadata = {
      if (drama.status.isNotEmpty) drama.status,
      if (drama.subTitle?.isNotEmpty ?? false) drama.subTitle!,
    }.join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 24,
                  height: 1.25,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.4,
                  color: Color(0xFF111827))),
        ),
        if (drama.score?.isNotEmpty ?? false) ...[
          const SizedBox(width: 10),
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF1F0),
              border: Border.all(color: const Color(0xFFFFE4E3)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.star_rounded, size: 14, color: detailAccent),
              const SizedBox(width: 2),
              Text(drama.score!,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: detailAccent)),
            ]),
          ),
        ],
      ]),
      if (metadata.isNotEmpty || tags.isNotEmpty) ...[
        const SizedBox(height: 9),
        Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (metadata.isNotEmpty)
                Text(metadata,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280))),
              ...tags.map((tag) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(tag,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF6B7280))),
                  )),
            ]),
      ],
    ]);
  }

  Future<void> _openAllEpisodes(List<Episode> episodes) async {
    final requestedId = drama.id;
    final season =
        _seasons?.seasons.where((s) => s.id == requestedId).firstOrNull;
    final index = await showDetailEpisodesSheet(
      context: context,
      title: drama.name,
      seasonLabel: season == null ? '' : '第${season.order}季 · ',
      episodes: episodes,
    );
    if (!mounted || requestedId != drama.id || index == null) return;
    _startPlay(context, episodeIndex: index);
  }

  Widget _buildCompactEpisodes() => FutureBuilder<TheaterEpisodesResult>(
        key: ValueKey('compact-episodes-${drama.id}'),
        future: _prefetchedEpisodes,
        builder: (context, snapshot) {
          final episodes = snapshot.data?.toEpisodes() ?? const <Episode>[];
          final seasonSelector = _buildSeasonSelector();
          return Column(
            key: const ValueKey('season-episode-selector'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('选集',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827))),
                if (episodes.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('全${episodes.length}集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9CA3AF)))),
                  TextButton(
                    key: const ValueKey('detail-show-all'),
                    onPressed: () => unawaited(_openAllEpisodes(episodes)),
                    style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF6B7280),
                        padding: EdgeInsets.zero),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('全部 ${episodes.length} 集',
                          style: const TextStyle(fontSize: 12)),
                      const Icon(Icons.chevron_right_rounded, size: 16),
                    ]),
                  ),
                ],
              ]),
              if (seasonSelector != null) ...[
                seasonSelector,
                const SizedBox(height: 6)
              ],
              if (snapshot.hasError)
                Center(
                    child: TextButton(
                        onPressed: () => setState(_prefetchEpisodes),
                        child: const Text('选集加载失败，点击重试')))
              else if (!snapshot.hasData)
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CupertinoActivityIndicator()))
              else if (episodes.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('暂无剧集',
                        style: TextStyle(color: Color(0xFF9CA3AF))))
              else
                DetailEpisodeStrip(
                  key: ValueKey('episodes-${drama.id}'),
                  episodes: episodes,
                  onSelect: (index) => _startPlay(context, episodeIndex: index),
                  onShowAll: () => unawaited(_openAllEpisodes(episodes)),
                ),
            ],
          );
        },
      );

  Widget _buildImmersiveActions(BuildContext context) => DetailActionBar(
        key: const ValueKey('detail-play-bar'),
        onPlay: () => _startPlay(context),
        onDownload: widget.downloadService != null && drama.isTheaterResource
            ? () => _downloadAll(context)
            : null,
        addingDownloads: _addingDownloads,
      );

  Widget _buildSliverAppBar(BuildContext context, Size size) {
    return SliverAppBar(
      // 比原封面加高约 30dp，留出更自然的渐隐空间。
      expandedHeight: (size.width * .82).clamp(240.0, 330.0) -
          MediaQuery.paddingOf(context).top,
      pinned: true,
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: TvTap(
        borderRadius: 24,
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .24),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: .25),
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
                      alignment: Alignment.topCenter,
                      errorBuilder: (_, __, ___) => _buildGradientBg(),
                    )
                  : _buildGradientBg(),
            ),
            // 在较长距离内逐渐增大白色透明度，避免封面底部出现突兀白带。
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 120,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00FFFFFF),
                      Color(0x0AFFFFFF),
                      Color(0x33FFFFFF),
                      Color(0x8CFFFFFF),
                      Color(0xE6FFFFFF),
                      Colors.white,
                    ],
                    stops: [0.0, 0.2, 0.46, 0.7, 0.9, 1.0],
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
    final tags = <String>{
      if (drama.pureCategoryTags?.isNotEmpty ?? false)
        ...drama.pureCategoryTags!
            .split(RegExp(r'[,，·]'))
            .where((tag) => tag.trim().isNotEmpty)
            .map((tag) => tag.trim()),
      if (drama.status.isNotEmpty) drama.status,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(drama.name,
          style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF252A36),
              height: 1.35,
              letterSpacing: -.4)),
      if (drama.subTitle?.isNotEmpty ?? false) ...[
        const SizedBox(height: 6),
        Text(drama.subTitle!,
            style: const TextStyle(
                fontSize: 12, height: 1.5, color: Color(0xFF969CAB))),
      ],
      if (tags.isNotEmpty || (drama.score?.isNotEmpty ?? false)) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (drama.score?.isNotEmpty ?? false)
            _metadataBadge(drama.score!, icon: Icons.star_rounded, score: true),
          ...tags.take(4).map((tag) => _metadataBadge(tag)),
        ]),
      ],
      if (drama.recText?.isNotEmpty ?? false) ...[
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.local_fire_department_rounded,
              size: 14, color: Color(0xFFEF7786)),
          const SizedBox(width: 4),
          Expanded(
              child: Text(drama.recText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF969CAB)))),
        ]),
      ],
    ]);
  }

  Widget _metadataBadge(String label, {IconData? icon, bool score = false}) =>
      Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: score ? const Color(0xFFFFF4E5) : const Color(0xFFF5F6FA),
              borderRadius: BorderRadius.circular(6)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: const Color(0xFFCE8B35)),
              const SizedBox(width: 3),
            ],
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: score ? FontWeight.w600 : FontWeight.w400,
                    color: score
                        ? const Color(0xFFB97B2B)
                        : const Color(0xFF858B9A))),
          ]));

  Widget _buildActionButtons(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF2E55).withValues(alpha: .12),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
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
              child: TvTap(
                ink: true,
                // 电视上进详情页默认选中“播放”，按 OK 直接开播
                autofocus: DeviceProfile.isTv,
                onTap: () => _startPlay(context),
                borderRadius: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
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
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE8EAF0)),
            ),
            child: Material(
              color: Colors.transparent,
              child: TvTap(
                ink: true,
                onTap: _addingDownloads ? null : () => _downloadAll(context),
                borderRadius: 12,
                child: _addingDownloads
                    ? const Center(child: CupertinoActivityIndicator())
                    : const Icon(
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

  Widget _buildIntroSection(BuildContext context) => drama.intro.isEmpty
      ? const SizedBox.shrink()
      : ExpandableSynopsis(
          key: ValueKey('synopsis-${drama.id}'), text: drama.intro);

  // ─── 电视 / 桌面宽屏布局 ───────────────────────────────────────────────
  // 左侧竖版海报，右侧信息 + 播放按钮 + 选集网格。全部内容一屏放下，
  // 方向键：播放按钮默认选中，按“下”进入选集，按返回键退出。
  Widget _buildWideLayout(BuildContext context) {
    final cover = drama.cover.isNotEmpty
        ? Image.network(
            drama.cover,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildGradientBg(),
          )
        : _buildGradientBg();

    if (DeviceProfile.isTv) {
      return TvDramaDetailView(
        drama: drama,
        cover: cover,
        onBack: () => Navigator.of(context).pop(),
        onPlay: () => _startPlay(context),
        onDownload: widget.downloadService != null && drama.isTheaterResource
            ? () => _downloadAll(context)
            : null,
        addingDownloads: _addingDownloads,
        episodes: _prefetchedEpisodes != null ? _buildWideEpisodeGrid() : null,
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 32, 48, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 3 / 4,
                child: Hero(
                  tag: 'drama_cover_${drama.id}',
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(40),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: cover,
                  ),
                ),
              ),
              const SizedBox(width: 40),
              Expanded(
                child: SingleChildScrollView(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeaderInfo(context),
                    if (drama.intro.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildIntroSection(context),
                    ],
                    const SizedBox(height: 20),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: _buildActionButtons(context),
                    ),
                    const SizedBox(height: 20),
                    if (_prefetchedEpisodes != null)
                      SizedBox(height: 260, child: _buildWideEpisodeGrid()),
                  ],
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWideEpisodeGrid({bool embedded = false}) {
    final seasonSelector = _buildSeasonSelector();
    final currentSeason =
        _seasons?.seasons.where((s) => s.id == drama.id).firstOrNull;
    final seasonDescription = currentSeason == null
        ? drama.subTitle ?? ''
        : '${_seasons!.seasons.length}季${currentSeason.episodeCount > 0 ? ' · 本季${currentSeason.episodeCount}集' : ''}';
    final episodeBody = FutureBuilder<TheaterEpisodesResult>(
      key: ValueKey(drama.id),
      future: _prefetchedEpisodes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
              child: TextButton(
                  onPressed: () => setState(_prefetchEpisodes),
                  child: const Text('选集加载失败，点击重试')));
        }
        if (!snapshot.hasData) {
          return const Center(child: CupertinoActivityIndicator());
        }
        final episodes = snapshot.data!.toEpisodes();
        if (episodes.isEmpty) return const Center(child: Text('暂无剧集'));
        return EpisodeSelector(
          key: ValueKey('episodes-${drama.id}'),
          episodes: episodes,
          activeIndex: 0,
          onSelect: (index) => _startPlay(context, episodeIndex: index),
          autofocusActive: false,
          softStyle: true,
          embedded: embedded,
          horizontalPadding: 0,
        );
      },
    );
    return Column(
      key: const ValueKey('season-episode-selector'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            const Text('选集',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF252A36))),
            const SizedBox(width: 12),
            if (seasonDescription.isNotEmpty)
              Expanded(
                  child: Text(seasonDescription,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF969CAB)))),
          ]),
        ),
        if (seasonSelector != null) ...[
          seasonSelector,
          const SizedBox(height: 6),
        ],
        if (embedded) episodeBody else Expanded(child: episodeBody),
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
