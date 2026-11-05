part of '../drama_detail_page.dart';

/// 数据加载（季列表、剧集目录、播放历史）与播放 / 缓存操作。
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

  // 加载详情页展示所需的剧集目录，不解析视频地址或预热视频数据。
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
    // 目录区域尚未构建或页面已退出时，也接住失败；原 Future 仍供界面显示错误。
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
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
              seasons: _seasons,
            ),
          ),
        )
        .then((_) => _loadHistory());
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
