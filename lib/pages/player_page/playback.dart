part of '../player_page.dart';

/// 播放中自动保存进度的间隔。
const int _kHistorySaveIntervalMs = 10000;

/// 播放主流程：拉剧集目录 → 解析地址 → 创建/复用播放器 → 订阅进度，
/// 以及自动下一集、播放历史、定时停止。
extension _PlayerPlayback on _PlayerPageState {
  // ─── 数据加载 ──────────────────────────────────────────────────────────

  String get _resolveStepLabel => isOfflinePlayback ? '读取本地缓存' : '解析播放地址';

  Future<void> _prepare() async {
    final catalogRequest = ++_catalogRequestId;
    _errorMessage = null;
    _steps = [
      const WorkflowStep(
          id: 'episodes', label: '获取剧集列表', status: StepStatus.running),
      WorkflowStep(id: 'resolve', label: _resolveStepLabel),
      const WorkflowStep(id: 'player', label: '初始化播放器'),
    ];
    _refresh();

    try {
      if (widget.offlineEpisodes != null) {
        _episodes = widget.offlineEpisodes!;
      } else if (_selectedSeasonDrama == null &&
          widget.prefetchedEpisodes != null) {
        final result = await widget.prefetchedEpisodes!;
        if (!mounted || catalogRequest != _catalogRequestId) return;
        _episodes = result.toEpisodes();
      } else {
        final result = await _fetchSeasonEpisodes(_drama.id);
        if (!mounted || catalogRequest != _catalogRequestId) return;
        _episodes = result.toEpisodes();
        // 切季时先用季卡片的简略信息，目录返回后补全剧名、封面和简介。
        final info = result.bookInfo;
        if (_selectedSeasonDrama != null &&
            info != null &&
            info.id == _drama.id) {
          _selectedSeasonDrama = info;
        }
      }

      if (!mounted || catalogRequest != _catalogRequestId) return;
      _updateStep('episodes', StepStatus.success);
      _updateStep('resolve', StepStatus.running);

      if (_episodes.isEmpty) {
        _refresh(() {
          _loading = false;
          _errorMessage = '暂无可播放的剧集';
        });
        return;
      }
      if (_selectedSeasonDrama == null && widget.initialEpisodeNumber != null) {
        final idx = _episodes.indexWhere(
          (episode) => episode.index == widget.initialEpisodeNumber,
        );
        if (idx >= 0 && idx < _episodes.length) _currentEpisodeIndex = idx;
      }
      _currentEpisodeIndex =
          _currentEpisodeIndex.clamp(0, _episodes.length - 1);
      _pageController =
          PageController(initialPage: _currentEpisodeIndex, keepPage: false);
      await _openEpisode(
        _currentEpisodeIndex,
        initialSeekMs:
            _selectedSeasonDrama == null ? widget.initialPositionMs : null,
      );
    } catch (e) {
      if (!mounted || catalogRequest != _catalogRequestId) return;
      _refresh(() {
        _loading = false;
        _errorMessage = '加载失败: $e';
      });
    }
  }

  void _updateStep(String id, StepStatus status) {
    _steps =
        _steps.map((s) => s.id == id ? s.copyWith(status: status) : s).toList();
    if (mounted) _refresh();
  }

  /// 以错误结束本次加载。
  void _failLoading(String message) {
    _refresh(() {
      _loading = false;
      _errorMessage = message;
    });
  }

  // ─── 打开剧集 ──────────────────────────────────────────────────────────

  Future<void> _openEpisode(int index, {int? initialSeekMs}) async {
    if (_sleepStopped || index < 0 || index >= _episodes.length) return;
    final reqId = ++_requestId;
    _errorMessage = null;
    if (_preparingPlayer != null) {
      enqueueDispose(_preparingPlayer!);
      _preparingPlayer = null;
    }

    final direction = index - _currentEpisodeIndex;
    _currentEpisodeIndex = index;
    _didPreloadN2 = false;
    _didPreloadN3 = false;
    _cancelPlayerSubscriptions();

    final reusedPlayer = _takeWindowPlayer(index, direction);
    if (reusedPlayer != null) {
      _activateReusedPlayer(reusedPlayer, reqId, initialSeekMs);
      return;
    }

    // 新建播放器路径
    _steps = [
      const WorkflowStep(
          id: 'episodes', label: '获取剧集列表', status: StepStatus.success),
      WorkflowStep(
          id: 'resolve', label: _resolveStepLabel, status: StepStatus.running),
      const WorkflowStep(id: 'player', label: '初始化播放器'),
    ];
    _refresh(() {
      _loading = true;
      _playerInitialized = false;
    });

    final videoId = _episodes[index].url.trim();
    if (videoId.isEmpty) {
      if (!mounted) return;
      _failLoading('视频地址为空');
      return;
    }

    final ({String cdnUrl, String keyHex})? source;
    try {
      source = await _resolveSource(videoId, index, reqId);
    } catch (e) {
      if (!mounted || reqId != _requestId) return;
      _failLoading('$_resolveStepLabel失败: $e');
      return;
    }
    if (!mounted || reqId != _requestId) return;
    if (source == null) {
      _failLoading('无效的播放地址');
      return;
    }
    final (:cdnUrl, :keyHex) = source;

    _updateStep('resolve', StepStatus.success);
    _updateStep('player', StepStatus.running);

    final player = NativePlayer();
    _preparingPlayer = player;
    try {
      if (keyHex.isNotEmpty) {
        await CryptoNativeChannel.instance.prewarm(cdnUrl, keyHex);
      }
      if (!mounted || reqId != _requestId) {
        await player.dispose();
        return;
      }
      await player.create(cdnUrl, keyHex);
    } catch (e) {
      if (identical(_preparingPlayer, player)) _preparingPlayer = null;
      await player.dispose();
      if (!mounted || reqId != _requestId) return;
      _failLoading('创建播放器失败: $e');
      return;
    }

    if (!mounted || reqId != _requestId) {
      unawaited(player.dispose());
      return;
    }

    // 先 play，让 AVPlayer 开始缓冲和解码
    unawaited(player.play());
    unawaited(player.setRate(_effectiveRate));
    if (initialSeekMs != null && initialSeekMs > 0) {
      unawaited(player.seek(Duration(milliseconds: initialSeekMs)));
    }

    // 等首帧渲染出来再隐藏 loading（避免黑屏闪烁）
    try {
      await player.waitForFirstFrame();
    } catch (error) {
      if (identical(_preparingPlayer, player)) _preparingPlayer = null;
      if (!mounted || reqId != _requestId) {
        unawaited(player.dispose());
        return;
      }
      _failLoading(error is TimeoutException ? '视频加载超时，请重试' : '播放失败: $error');
      unawaited(player.dispose());
      return;
    }

    if (!mounted || reqId != _requestId) {
      unawaited(player.dispose());
      return;
    }

    if (identical(_preparingPlayer, player)) _preparingPlayer = null;
    _player = player;
    _playerInitialized = true;
    _loading = false;
    _showNextLoading = false;
    positionMsNotifier.value = player.position.inMilliseconds;
    durationMsNotifier.value = player.duration.inMilliseconds;
    playingNotifier.value = true;
    _refresh();

    _updateStep('player', StepStatus.success);
    _onEpisodeStarted(player, reqId, initialSeekMs);
  }

  /// 3-Player 窗口：切到相邻集且那一集已准备好时，交换引用直接复用；
  /// 否则释放整个窗口，返回 null 走新建路径。
  NativePlayer? _takeWindowPlayer(int index, int direction) {
    if (direction > 0 && nextPlayer != null && nextEpisodeIndex == index) {
      if (_player != null) {
        unawaited(_player!.pause());
        unawaited(_player!.setVolume(0));
        // 降级为上一集：停放加密流，不再和新的当前集抢带宽
        unawaited(_player!.setActive(false));
        if (prevPlayer != null) enqueueDispose(prevPlayer!);
        prevPlayer = _player;
        prevEpisodeIndex = index - 1;
        prevPositionMs = _player!.position.inMilliseconds;
      }
      final reused = nextPlayer;
      nextPlayer = null;
      nextEpisodeIndex = null;
      nextPlayerReady = false;
      return reused;
    }
    if (direction < 0 && prevPlayer != null && prevEpisodeIndex == index) {
      if (_player != null) {
        unawaited(_player!.pause());
        unawaited(_player!.setVolume(0));
        // 降级为下一集：停放加密流
        unawaited(_player!.setActive(false));
        if (nextPlayer != null) enqueueDispose(nextPlayer!);
        nextPlayer = _player;
        nextEpisodeIndex = index + 1;
        nextPlayerReady = true;
      }
      final reused = prevPlayer;
      prevPlayer = null;
      prevEpisodeIndex = null;
      prevPositionMs = null;
      return reused;
    }
    if (_player != null) {
      unawaited(_player!.pause());
      enqueueDispose(_player!);
    }
    dispose3PWindow();
    return null;
  }

  void _activateReusedPlayer(
      NativePlayer reusedPlayer, int reqId, int? initialSeekMs) {
    if (reusedPlayer.completed) {
      unawaited(reusedPlayer.seek(Duration.zero));
    }
    _player = reusedPlayer;
    _playerInitialized = true;
    _loading = false;
    _showNextLoading = false;
    positionMsNotifier.value = reusedPlayer.position.inMilliseconds;
    durationMsNotifier.value = reusedPlayer.duration.inMilliseconds;
    playingNotifier.value = reusedPlayer.playing;
    _refresh();
    // 升为当前集：恢复正常预读
    unawaited(reusedPlayer.setActive(true));
    unawaited(reusedPlayer.setVolume(1.0));
    unawaited(reusedPlayer.setRate(_effectiveRate));
    unawaited(reusedPlayer.play());
    if (initialSeekMs != null && initialSeekMs > 0) {
      unawaited(reusedPlayer.seek(Duration(milliseconds: initialSeekMs)));
    }
    _onEpisodeStarted(reusedPlayer, reqId, initialSeekMs);
  }

  /// 新的一集开始播放后的公共收尾：订阅、弹幕、预热、预取下一季、记历史。
  void _onEpisodeStarted(NativePlayer player, int reqId, int? initialSeekMs) {
    _setupSubscriptions(player, reqId);
    _danmakuController.clearComments();
    _loadDanmaku(positionMs: initialSeekMs);
    schedulePreloads(_currentEpisodeIndex);
    _maybePrefetchNextSeason();
    _saveHistory(positionMs: initialSeekMs);
  }

  /// 解析本集的播放源。离线播放读本地文件；`crypto://<cdn>?key=<hex>`
  /// 拆成 CDN 地址与密钥；格式不对时返回 null。
  Future<({String cdnUrl, String keyHex})?> _resolveSource(
      String videoId, int index, int reqId) async {
    if (isOfflinePlayback) {
      return (
        cdnUrl: await OfflinePlaybackCache.playableFileUri(videoId),
        keyHex: '',
      );
    }
    final url = await _preloadManager.resolvePlayUrl(
      videoId,
      episodeIndex: index,
    );
    if (!url.startsWith('crypto://')) return (cdnUrl: url, keyHex: '');
    final encoded = url.substring('crypto://'.length);
    final qIdx = encoded.indexOf('?key=');
    if (qIdx < 0) return null;
    return (
      cdnUrl: Uri.decodeComponent(encoded.substring(0, qIdx)),
      keyHex: encoded.substring(qIdx + 5),
    );
  }

  // ─── 订阅 ──────────────────────────────────────────────────────────────

  void _setupSubscriptions(NativePlayer player, int reqId) {
    _errorSub = player.errorStream.listen((message) {
      if (!mounted || reqId != _requestId) return;
      _failLoading('播放失败: $message');
    });
    _positionSub = player.positionStream.listen((pos) {
      if (reqId != _requestId) return;
      positionMsNotifier.value = pos.inMilliseconds;
      _checkPreloadThresholds(pos, player.duration);
      if (player.playing) _maybeSaveHistoryPeriodically();
    });
    _playingSub = player.playingStream.listen((playing) {
      if (reqId != _requestId) return;
      playingNotifier.value = playing;
    });
    _completedSub = player.completedStream.listen((completed) {
      if (reqId != _requestId) return;
      if (completed) _onAutoNext();
    });
    _durationSub = player.durationStream.listen((dur) {
      if (reqId != _requestId) return;
      durationMsNotifier.value = dur.inMilliseconds;
    });
  }

  void _cancelPlayerSubscriptions() {
    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _durationSub?.cancel();
  }

  void _checkPreloadThresholds(Duration position, Duration duration) {
    if (duration <= Duration.zero) return;
    final progress = position.inMilliseconds / duration.inMilliseconds;
    if (!_didPreloadN2 && progress >= 0.5) {
      _didPreloadN2 = true;
      preloadHeaderOnly(_currentEpisodeIndex, _currentEpisodeIndex + 2);
    }
    if (!_didPreloadN3 && progress >= 0.75) {
      _didPreloadN3 = true;
      preloadHeaderOnly(_currentEpisodeIndex, _currentEpisodeIndex + 3);
    }
    // 持续加载弹幕下一批
    unawaited(_danmakuController.ensureLoadedUpTo(
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      isTheaterResource: _drama.isTheaterResource,
      isOfflinePlayback: isOfflinePlayback,
    ));
  }

  // ─── 自动下一集 ────────────────────────────────────────────────────────

  void _onAutoNext() {
    _sleepTimer.checkDeadline();
    if (_sleepStopped || _userPaused) return;
    final next = _currentEpisodeIndex + 1;
    if (next >= _episodes.length) {
      if (_canAdvanceSeason) unawaited(_advanceToNextSeason());
      return;
    }
    _programmaticJump = true;
    _pageController?.animateToPage(
      next,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeInOut,
    );
    _programmaticJump = false;
    unawaited(_openEpisode(next));
  }

  // ─── 播放历史 ──────────────────────────────────────────────────────────

  /// 写播放记录。[positionMs] 不传时取当前进度；开播时传入续播位置，
  /// 避免 seek 还没生效就把记录覆盖成 0。
  void _saveHistory({int? positionMs}) {
    if (_episodes.isEmpty || _currentEpisodeIndex >= _episodes.length) return;
    final drama = _drama;
    final posMs = positionMs ??
        (_playerInitialized
            ? positionMsNotifier.value
            : _player?.position.inMilliseconds ?? 0);
    final durationMs = durationMsNotifier.value;
    _lastHistorySaveMs = DateTime.now().millisecondsSinceEpoch;
    unawaited(
      PlaybackHistoryStore.upsert(PlaybackRecord(
        dramaId: drama.id,
        dramaName: drama.name,
        cover: drama.cover,
        episodeIndex: _currentEpisodeIndex,
        episodeNumber: _episodes[_currentEpisodeIndex].index,
        positionMs: posMs,
        durationMs: durationMs > 0 ? durationMs : null,
        episodeCount: _episodes.length,
        updatedAtMs: _lastHistorySaveMs,
      )),
    );
  }

  /// 播放中每隔一段时间保存一次进度，App 被系统杀掉时也不会丢太多。
  void _maybeSaveHistoryPeriodically() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastHistorySaveMs >= _kHistorySaveIntervalMs) _saveHistory();
  }

  // ─── 定时停止 ──────────────────────────────────────────────────────────

  void _stopForSleep() {
    if (!mounted) return;
    if (!_sleepStopped) {
      _sleepPositionMs = _playerInitialized ? positionMsNotifier.value : 0;
    }
    if (_playerInitialized) _saveHistory();
    _sleepStopped = true;
    _userPaused = true;
    _pausedByLifecycle = false;
    _pausedByRoute = false;
    _resumeAfterSeek = false;
    ++_requestId; // 在加载中到期时，禁止旧异步请求重新开始播放。
    _cancelPlayerSubscriptions();
    if (_player != null) enqueueDispose(_player!);
    if (_preparingPlayer != null) enqueueDispose(_preparingPlayer!);
    _player = null;
    _preparingPlayer = null;
    dispose3PWindow();
    _swipeBlockTimer?.cancel();
    playingNotifier.value = false;
    unawaited(NativePlayer.setKeepScreenOn(false));
    _systemUi.showUIAndResetTimer();
    _refresh(() {
      _playerInitialized = false;
      _loading = false;
      _showNextLoading = false;
      _swipeBlocked = false;
      _errorMessage = null;
    });
    showAppNotice(context,
        message: '定时已结束',
        detail: '播放已停止，点击播放按钮可继续',
        kind: AppNoticeKind.info,
        abovePlayerControls: true);
  }
}
