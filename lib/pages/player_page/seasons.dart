part of '../player_page.dart';

/// 最后一集继续上滑超过这个距离（逻辑像素）就进入下一季。
const double _kSeasonSwipeThreshold = 72;

/// 跨季连播：加载季列表、在最后一集预取下一季、切季。
extension _PlayerSeasons on _PlayerPageState {
  Future<void> _loadSeasons() async {
    if (isOfflinePlayback || !widget.drama.isTheaterResource) return;
    try {
      final seasons =
          await widget.apiClient.fetchDramaSeasons(widget.drama.id.toString());
      if (!mounted) return;
      _seasons = seasons;
      _maybePrefetchNextSeason();
      // 已经在最后一集时，“下一集”按钮要变成可用
      _refresh();
    } catch (error) {
      debugPrint('播放页加载季列表失败（不影响本季播放）: $error');
    }
  }

  DramaSeason? get _nextSeason =>
      isOfflinePlayback ? null : _seasons?.nextAfter(_drama.id);

  bool get _isLastEpisode =>
      _episodes.isNotEmpty && _currentEpisodeIndex >= _episodes.length - 1;

  bool get _canAdvanceSeason =>
      !_seasonAdvancing && _isLastEpisode && _nextSeason != null;

  /// 到了本季最后一集：后台拉下一季目录并预热它的第 1 集。
  void _maybePrefetchNextSeason() {
    if (!_isLastEpisode) return;
    final season = _nextSeason;
    if (season == null || _nextSeasonPrefetchId == season.id) return;
    _nextSeasonPrefetchId = season.id;
    _nextSeasonFirstVideoId = null;
    final future = widget.apiClient.fetchTheaterEpisodes(season.id.toString());
    _nextSeasonEpisodes = future;
    bool stillCurrent() => mounted && _nextSeasonPrefetchId == season.id;
    unawaited(() async {
      try {
        final episodes = (await future).toEpisodes();
        if (!stillCurrent() || episodes.isEmpty) return;
        _nextSeasonFirstVideoId = episodes.first.url.trim();
        await _preloadManager.preloadEpisode(
          episodes: episodes,
          currentIndex: -1,
          targetIndex: 0,
          isStillCurrent: stillCurrent,
        );
        debugPrint('下一季首集预热完成: ${season.title}');
      } catch (error) {
        debugPrint('下一季预取失败（切季时会重新请求）: $error');
      }
    }());
  }

  /// 取剧集目录：命中下一季预取就直接用，失败或没有预取时再请求。
  Future<TheaterEpisodesResult> _fetchSeasonEpisodes(int dramaId) async {
    final prefetched =
        _nextSeasonPrefetchId == dramaId ? _nextSeasonEpisodes : null;
    _nextSeasonPrefetchId = null;
    _nextSeasonEpisodes = null;
    _nextSeasonFirstVideoId = null;
    if (prefetched != null) {
      try {
        return await prefetched;
      } catch (_) {
        // 预取失败时重新请求一次
      }
    }
    return widget.apiClient.fetchTheaterEpisodes(dramaId.toString());
  }

  /// 本季播完、最后一集继续上滑、或点“下一集”时进入下一季。
  Future<void> _advanceToNextSeason() async {
    final season = _nextSeason;
    if (season == null || _seasonAdvancing || _sleepStopped || !mounted) {
      return;
    }
    _seasonAdvancing = true;
    final label = season.order > 0 ? '第${season.order}季' : season.title;
    showAppNotice(context,
        message: '已进入$label',
        kind: AppNoticeKind.info,
        abovePlayerControls: true);
    try {
      await _switchSeason(season);
    } finally {
      _seasonAdvancing = false;
    }
  }

  Future<void> _switchSeason(DramaSeason season) async {
    if (!mounted || isOfflinePlayback || season.id == _drama.id) return;
    if (_playerInitialized) _saveHistory();
    ++_requestId;
    ++_catalogRequestId;
    _cancelPlayerSubscriptions();
    final oldPlayer = _player;
    final preparingPlayer = _preparingPlayer;
    _player = null;
    _preparingPlayer = null;
    dispose3PWindow();
    // 自动接下一季时首集已提前预热：保留它的解析结果，避免重新签名导致预热失效。
    final keepVideoId =
        _nextSeasonPrefetchId == season.id ? _nextSeasonFirstVideoId : null;
    _preloadManager.clear(
        keepVideoIds: keepVideoId == null ? const [] : [keepVideoId]);
    _danmakuController.clearComments();
    _swipeBlockTimer?.cancel();
    _pageController?.dispose();
    _pageController = null;
    positionMsNotifier.value = 0;
    durationMsNotifier.value = 0;
    playingNotifier.value = false;
    _refresh(() {
      _selectedSeasonDrama = season.toDrama();
      _episodes = const [];
      _currentEpisodeIndex = 0;
      _playerInitialized = false;
      _loading = true;
      _errorMessage = null;
      _showNextLoading = false;
      _swipeBlocked = false;
      _seekingPositionMs = null;
      _userPaused = false;
      _sleepStopped = false;
      _pausedByLifecycle = false;
      _pausedByRoute = false;
    });
    // 释放上一季后再开新播放器，避免两季同时出声、占用解码器。
    if (oldPlayer != null) await oldPlayer.dispose();
    if (preparingPlayer != null) await preparingPlayer.dispose();
    if (!mounted) return;
    unawaited(NativePlayer.setKeepScreenOn(true));
    await _prepare();
  }
}
