part of '../player_page.dart';

/// 播放控制回调：暂停/播放、拖动进度、倍速、清晰度、定时、弹幕、
/// 切集翻页、横屏、更多菜单与选集面板。
extension _PlayerControls on _PlayerPageState {
  // ─── 播放 / 暂停 ───────────────────────────────────────────────────────

  void _onTogglePlay() {
    if (_sleepStopped) {
      _sleepStopped = false;
      _userPaused = false;
      unawaited(NativePlayer.setKeepScreenOn(true));
      unawaited(
          _openEpisode(_currentEpisodeIndex, initialSeekMs: _sleepPositionMs));
      return;
    }
    final player = _player;
    if (player == null || !_playerInitialized) return;
    if (player.playing) {
      _userPaused = true;
      unawaited(player.pause());
      _saveHistory();
    } else {
      _userPaused = false;
      if (_isDirectVideo && player.completed) {
        unawaited(player.seek(Duration.zero));
      }
      unawaited(player.play());
    }
    _refresh();
  }

  // 红果：竖屏单击暂停/播放；横屏单击显示/隐藏控件，双击暂停/播放。
  void _onTapVideo() {
    if (_systemUi.isLandscapeFullScreen || DeviceProfile.usesFocusUi) {
      _systemUi.toggleLandscapeUi();
    } else {
      _onTogglePlay();
    }
  }

  void _onDoubleTapVideo() {
    _onTogglePlay();
  }

  // ─── 拖动进度 ──────────────────────────────────────────────────────────

  void _onSeekStart(double ms) {
    final player = _player;
    if (player == null || !_playerInitialized) return;
    _resumeAfterSeek = player.playing;
    player.pause();
    _refresh(() => _seekingPositionMs = ms);
  }

  // 拖动时刷新屏幕中间的大号时间
  void _onSeekChanged(double ms) {
    _refresh(() => _seekingPositionMs = ms);
  }

  void _onSeekEnd(double ms) {
    final player = _player;
    if (player != null && _playerInitialized) {
      player.seek(Duration(milliseconds: ms.toInt()));
      positionMsNotifier.value = ms.toInt();
      _onDanmakuSeek(ms.toInt());
      if (_resumeAfterSeek) {
        player.play();
      }
    }
    // 横竖屏切换/翻页时 Slider 被卸载也会触发 dragEnd，此时框架处于锁定阶段，
    // 不能直接 setState。
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh(() => _seekingPositionMs = null);
      });
    } else {
      _refresh(() => _seekingPositionMs = null);
    }
  }

  void _seekBy(int deltaMs) {
    final player = _player;
    if (player == null || !_playerInitialized) return;
    _systemUi.showUIAndResetTimer();
    final duration = durationMsNotifier.value;
    var target = positionMsNotifier.value + deltaMs;
    if (target < 0) target = 0;
    if (duration > 0 && target > duration - 500) target = duration - 500;
    unawaited(player.seek(Duration(milliseconds: target)));
    positionMsNotifier.value = target;
    _onDanmakuSeek(target);
    _refresh();
  }

  // ─── 倍速 ──────────────────────────────────────────────────────────────

  /// 当前应生效的播放速率：长按加速时固定 2 倍。
  double get _effectiveRate => _isSpeedUp ? 2.0 : _playbackSpeed;

  void _applyRate(double rate) {
    if (_player != null && _playerInitialized) {
      unawaited(_player!.setRate(rate));
    }
  }

  void _onSpeedTap() {
    const speeds = [1.0, 1.25, 1.5, 2.0];
    final idx = speeds.indexOf(_playbackSpeed);
    _playbackSpeed = speeds[(idx + 1) % speeds.length];
    _applyRate(_playbackSpeed);
    _refresh();
  }

  void _onSpeedChanged(double value) {
    _playbackSpeed = value;
    _applyRate(value);
    _refresh();
  }

  void _onLongPressStart(LongPressStartDetails _) {
    _isSpeedUp = true;
    _applyRate(2.0);
    _refresh();
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    if (_activePointers > 0) return;
    _isSpeedUp = false;
    _applyRate(_playbackSpeed);
    _refresh();
  }

  void _endSpeedUp() {
    if (!_isSpeedUp) return;
    _isSpeedUp = false;
    _applyRate(_playbackSpeed);
    _refresh();
  }

  // ─── 清晰度 / 定时 ─────────────────────────────────────────────────────

  void _onQualityChanged(String value) {
    if (isOfflinePlayback || _episodes.isEmpty) return;
    if (value ==
        _preloadManager
            .selectedDefinition(_episodes[_currentEpisodeIndex].url.trim())) {
      return;
    }
    _preloadManager.setPreferredDefinition(value);
    // 换清晰度会重新打开本集并自动播放，清掉“用户已暂停”，否则播放图标会挂着
    _userPaused = false;
    unawaited(_openEpisode(_currentEpisodeIndex,
        initialSeekMs: positionMsNotifier.value));
    _refresh();
  }

  void _onSleepDurationChanged(Duration? duration) {
    if (duration == null || duration == Duration.zero) {
      _sleepTimerMinutes = null;
      _sleepTimer.cancel();
    } else {
      _sleepTimerMinutes = duration.inMinutes;
      _sleepTimer.start(duration);
    }
    _refresh();
  }

  // ─── 弹幕 ──────────────────────────────────────────────────────────────

  void _onToggleDanmaku() {
    if (_isDirectVideo) return;
    unawaited(_danmakuController.toggle(
      isOfflinePlayback: isOfflinePlayback,
      currentEpisode:
          _episodes.isNotEmpty ? _episodes[_currentEpisodeIndex] : null,
      bookId: _drama.id.toString(),
      durationMs: durationMsNotifier.value,
      positionMs: positionMsNotifier.value,
    ));
    _refresh();
  }

  void _loadDanmaku({int? positionMs}) {
    if (_isDirectVideo || isOfflinePlayback || !_drama.isTheaterResource) {
      return;
    }
    if (!_danmakuController.enabled) return;
    if (_currentEpisodeIndex >= _episodes.length) return;
    unawaited(_danmakuController.loadForEpisode(
      episode: _episodes[_currentEpisodeIndex],
      bookId: _drama.id.toString(),
      durationMs: durationMsNotifier.value,
      positionMs: positionMs ?? positionMsNotifier.value,
      isOfflinePlayback: isOfflinePlayback,
    ));
  }

  void _onDanmakuSeek(int positionMs) {
    if (_isDirectVideo) return;
    _danmakuSeekGeneration++;
    unawaited(_danmakuController.ensureLoadedUpTo(
      positionMs: positionMs,
      durationMs: durationMsNotifier.value,
      seek: true,
      isTheaterResource: _drama.isTheaterResource,
      isOfflinePlayback: isOfflinePlayback,
    ));
  }

  // ─── 切集 / 翻页 ───────────────────────────────────────────────────────

  void _jumpToEpisode(int idx) {
    if (!mounted || (idx == _currentEpisodeIndex && !_sleepStopped)) {
      return;
    }
    _sleepStopped = false;
    _userPaused = false;
    unawaited(NativePlayer.setKeepScreenOn(true));
    _programmaticJump = true;
    _pageController?.jumpToPage(idx);
    _programmaticJump = false;
    unawaited(_openEpisode(idx));
  }

  void _stepEpisode(int delta) {
    final target = _currentEpisodeIndex + delta;
    if (delta > 0 && target >= _episodes.length && _canAdvanceSeason) {
      _systemUi.showUIAndResetTimer();
      unawaited(_advanceToNextSeason());
      return;
    }
    if (target < 0 || target >= _episodes.length) return;
    _systemUi.showUIAndResetTimer();
    _jumpToEpisode(target);
  }

  /// 显示“下一集加载中”胶囊，5 秒后自动收起（之后允许翻页，走新建路径）。
  void _showSwipeBlocked() {
    _refresh(() => _swipeBlocked = true);
    _swipeBlockTimer?.cancel();
    _swipeBlockTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      _refresh(() => _swipeBlocked = false);
    });
  }

  void _onPageChanged(int index) {
    if (_sleepStopped) return;
    if (_programmaticJump) return;
    if (index == _currentEpisodeIndex) return;
    final isForward = index > _currentEpisodeIndex;

    // 向前滑且下一集没准备好：弹回原位并提示
    if (isForward && !nextPlayerReady && !_swipeBlocked) {
      _programmaticJump = true;
      _pageController?.animateToPage(
        _currentEpisodeIndex,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
      _programmaticJump = false;
      _showSwipeBlocked();
      return;
    }

    // 正常翻页：新的一集会自动播放，清掉上一集的“用户已暂停”状态，
    // 否则中间的播放图标会一直挂着
    _swipeBlockTimer?.cancel();
    _refresh(() {
      _swipeBlocked = false;
      _userPaused = false;
    });
    unawaited(_openEpisode(index));
  }

  // ─── 横屏 / 返回 ───────────────────────────────────────────────────────

  void _onToggleLandscapeFullScreen() {
    _systemUi.toggleLandscapeFullScreen();
    _refresh();
  }

  void _onToggleVideoFit() {
    _refresh(() => _landscapeFill = !_landscapeFill);
    _systemUi.showUIAndResetTimer();
  }

  void _onBack() {
    if (DeviceProfile.isTv && _systemUi.showLandscapeUI) {
      _systemUi.hideLandscapeUi();
      return;
    }
    if (_systemUi.isLandscapeFullScreen) {
      _onToggleLandscapeFullScreen();
      return;
    }
    Navigator.of(context).pop();
  }

  // ─── 底部面板 / 菜单 ───────────────────────────────────────────────────

  bool get _usesPhoneLayout => PlayerVideoSurface.usesPhoneLayout(
      MediaQuery.of(context).size, _systemUi.isLandscapeFullScreen);

  bool get _canDownload =>
      widget.downloadService != null &&
      !isOfflinePlayback &&
      _drama.isTheaterResource;

  void _onBottomPanelHeight(double height) {
    if (DeviceProfile.isTv) return;
    if (height <= 0) {
      unawaited(_episodeShrink.reverse());
      return;
    }
    if (!_usesPhoneLayout) return;
    _refresh(() => _shrinkPanelHeight = height);
    unawaited(_episodeShrink.forward());
  }

  /// 遥控器 / 键盘呼出的播放菜单（与右上角“…”同一套设置，外加“选集”入口）。
  Future<void> _openMoreMenu() async {
    if (_moreMenuOpen || !mounted || _episodes.isEmpty) return;
    _moreMenuOpen = true;
    _systemUi.setMenuOpen(true);
    final url = _episodes[_currentEpisodeIndex].url.trim();
    PlayerMenuAction? action;
    try {
      action = await showPlayerMoreSheet(
        context: context,
        canDownload: _canDownload,
        isOfflinePlayback: isOfflinePlayback,
        sleepTimerActive: _sleepTimer.isActive,
        danmakuEnabled: _danmakuController.enabled,
        playbackSpeed: _playbackSpeed,
        currentQuality: (_isDirectVideo || isOfflinePlayback)
            ? ''
            : _preloadManager.selectedDefinition(url),
        loadQualities: (_isDirectVideo || isOfflinePlayback)
            ? null
            : () => _preloadManager.availableDefinitions(url),
        onToggleDanmaku: _onToggleDanmaku,
        onSpeedChanged: _onSpeedChanged,
        onQualityChanged: _onQualityChanged,
        onSleepDurationChanged: _onSleepDurationChanged,
        sleepTimerMinutes: _sleepTimer.isActive ? _sleepTimerMinutes : null,
        showEpisodes: !_isDirectVideo,
        showDramaFeatures: !_isDirectVideo,
        onSheetLayout: _onBottomPanelHeight,
      );
      _onBottomPanelHeight(0);
    } finally {
      _moreMenuOpen = false;
      if (mounted) _systemUi.setMenuOpen(false);
    }
    if (!mounted || action == null) return;
    if (action == PlayerMenuAction.episodes) {
      await _onEpisodeTap();
    } else {
      await _onMenuAction(action);
    }
  }

  Future<void> _onEpisodeTap() async {
    if (_isDirectVideo) return;
    DramaSeason? selectedSeason;
    final episodeNotifier = ValueNotifier<int>(_currentEpisodeIndex);
    _systemUi.setMenuOpen(true);
    _shrinkPanelHeight = null; // 选集面板：屏高 50%
    final shrink = !DeviceProfile.isTv && _usesPhoneLayout;
    if (shrink) unawaited(_episodeShrink.forward());
    final status = _drama.status.trim();
    final onlineTheater = _drama.isTheaterResource && !isOfflinePlayback;
    try {
      await showPlayerEpisodeSheet(
        context: context,
        isLandscapeFullScreen: _systemUi.isLandscapeFullScreen,
        dramaName: _drama.name,
        episodes: _episodes,
        currentDramaId: _drama.id,
        loadSeasons: onlineTheater
            ? () => widget.apiClient.fetchDramaSeasons(_drama.id.toString())
            : null,
        onSelectSeason: (season) => selectedSeason = season,
        loadTitles: onlineTheater
            ? () => widget.apiClient.fetchEpisodeTitles(_drama.id.toString())
            : null,
        episodeNotifier: episodeNotifier,
        onSelectEpisode: _jumpToEpisode,
        cover: _drama.cover,
        intro: _drama.intro,
        status: status.isEmpty
            ? '共${_episodes.length}集'
            : '$status · 共${_episodes.length}集',
      );
    } finally {
      episodeNotifier.dispose();
      if (mounted) {
        if (shrink) unawaited(_episodeShrink.reverse());
        _systemUi.setMenuOpen(false);
      }
    }
    if (mounted && selectedSeason != null) {
      await _switchSeason(selectedSeason!);
    }
  }

  Future<void> _onMenuAction(PlayerMenuAction action) async {
    if (_actionSheetOpen) return;
    _actionSheetOpen = true;
    _systemUi.setMenuOpen(true);
    try {
      switch (action) {
        case PlayerMenuAction.episodes:
          break; // 由 _openMoreMenu 处理
        case PlayerMenuAction.download:
          await _downloadAllEpisodes();
      }
    } catch (error) {
      if (mounted) {
        showAppNotice(context,
            message: '操作未完成',
            detail: error is ApiException ? error.message : '请稍后重试',
            kind: AppNoticeKind.error,
            abovePlayerControls: true);
      }
    } finally {
      _actionSheetOpen = false;
      if (mounted) _systemUi.setMenuOpen(false);
    }
  }

  Future<void> _downloadAllEpisodes() async {
    final service = widget.downloadService;
    if (service == null || isOfflinePlayback) return;
    await service.ensureLoaded();
    if (!mounted) return;
    final count = await service.addDownloads(
      dramaId: _drama.id.toString(),
      dramaName: _drama.name,
      episodes: _episodes,
      coverUrl: _drama.cover.isEmpty ? null : _drama.cover,
      isTheaterResource: _drama.isTheaterResource,
    );
    if (mounted) {
      showAppNotice(context,
          message: count > 0 ? '缓存任务已添加' : '所选剧集无需重复下载',
          detail: count > 0 ? '已加入 $count 集，可在缓存页查看进度' : '已缓存或正在下载',
          kind: count > 0 ? AppNoticeKind.success : AppNoticeKind.info,
          abovePlayerControls: true);
    }
  }
}
