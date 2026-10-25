part of '../drama_detail_page.dart';

/// 数据加载（季列表、剧集预取、首集预热、播放历史）与播放 / 缓存操作。
extension _DetailActions on _DramaDetailPageState {
  Future<void> _loadSeasons() async {
    if (_loadingSeasons) return;
    _refresh(() {
      _loadingSeasons = true;
      _seasonsFailed = false;
    });
    try {
      final seasons = await apiClient.fetchDramaSeasons(
          widget.drama.id.toString(),
          cancelToken: _seasonsCancelToken);
      if (mounted) _refresh(() => _seasons = seasons);
    } catch (_) {
      if (mounted) _refresh(() => _seasonsFailed = true);
    } finally {
      if (mounted) _refresh(() => _loadingSeasons = false);
    }
  }

  void _openSeason(DramaSeason season) {
    if (season.id == drama.id) return;
    _refresh(() {
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
        _refresh(() => _detailDrama = result.bookInfo);
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
      _refresh(() {
        _lastEpisodeIndex = record.episodeIndex;
        _lastPositionMs = record.positionMs;
      });
    }
  }

  Future<void> _loadDramaDetail() async {
    if (mounted) {
      _refresh(() {
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
          seasons: _seasons,
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
    _refresh(() => _addingDownloads = true);
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
      if (mounted) _refresh(() => _addingDownloads = false);
    }
  }
}
