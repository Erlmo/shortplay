part of '../player_page.dart';

/// 播放中自动保存进度的间隔。
const int _kHistorySaveIntervalMs = 10000;

/// 播放主流程：拉剧集目录 → 解析地址 → 创建/复用播放器 → 订阅进度，
/// 以及自动下一集、播放历史、定时停止。
extension _PlayerPlayback on _PlayerPageState {
  // ─── 数据加载 ──────────────────────────────────────────────────────────

  String get _resolveStepLabel => _isDirectVideo
      ? '连接视频'
      : (isOfflinePlayback || cachedEpisodePath(_currentEpisodeIndex) != null
          ? '读取本地缓存'
          : '解析播放地址');

  Future<void> _prepare() async {
    final startupClock = Stopwatch()..start();
    final catalogRequest = ++_catalogRequestId;
    _errorMessage = null;
    _steps = [
      WorkflowStep(
          id: 'episodes',
          label: _isDirectVideo ? '准备视频' : '获取剧集列表',
          status: StepStatus.running),
      WorkflowStep(id: 'resolve', label: _resolveStepLabel),
      const WorkflowStep(id: 'player', label: '初始化播放器'),
    ];
    _refresh();

    try {
      if (_isDirectVideo) {
        final url = widget.directVideoUrl!;
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !['https', 'http'].contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw const FormatException('无效的视频地址');
        }
        _episodes = [Episode(index: 1, name: _drama.name, size: 0, url: url)];
      } else if (widget.offlineEpisodes != null) {
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
        startupClock: startupClock,
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

  Future<void> _openEpisode(int index,
      {int? initialSeekMs,
      Stopwatch? startupClock,
      QualitySwitchTicket? qualitySwitch}) async {
    if (qualitySwitch == null) _qualitySwitches.cancel();
    if (_sleepStopped || index < 0 || index >= _episodes.length) return;
    final startup = startupClock ?? (Stopwatch()..start());
    void trace(String stage) {
      if (const bool.fromEnvironment('SHORTPLAY_TRACE_STARTUP')) {
        debugPrint('[Startup] episode=${index + 1} stage=$stage '
            'elapsed_ms=${startup.elapsedMilliseconds} '
            'epoch_ms=${DateTime.now().millisecondsSinceEpoch}');
      }
    }

    trace('catalog_ready');
    cancelPlaybackPreparation();
    final reqId = ++_requestId;
    _errorMessage = null;
    if (_preparingPlayer != null) {
      enqueueDispose(_preparingPlayer!);
      _preparingPlayer = null;
    }

    final direction = index - _currentEpisodeIndex;
    _currentEpisodeIndex = index;
    _cancelPlayerSubscriptions();

    final reusedPlayer = _takeWindowPlayer(index, direction);
    if (reusedPlayer != null) {
      if (await _activateReusedPlayer(reusedPlayer, reqId, initialSeekMs)) {
        return;
      }
      if (!mounted || reqId != _requestId) return;
    }

    // 新建播放器路径
    _steps = [
      WorkflowStep(
          id: 'episodes',
          label: _isDirectVideo ? '准备视频' : '获取剧集列表',
          status: StepStatus.success),
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
    trace('source_ready');

    _updateStep('resolve', StepStatus.success);
    _updateStep('player', StepStatus.running);

    final player = NativePlayer();
    _preparingPlayer = player;
    try {
      // Apple 端保留起播媒体预取：只提前创建播放器，可能把等待
      // 转移到出画后的连续读取。Android 继续使用原生读取线程准备。
      if (keyHex.isNotEmpty &&
          defaultTargetPlatform != TargetPlatform.android) {
        await CryptoNativeChannel.instance.prewarm(cdnUrl, keyHex);
      }
      trace('create_started');
      if (!mounted || reqId != _requestId) {
        await player.dispose();
        return;
      }
      await player.create(cdnUrl, keyHex,
          initialPositionMs: qualitySwitch == null ? null : initialSeekMs);
      trace('player_created');
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

    if (qualitySwitch != null) {
      // Native creation positions the source before preparing its first frame.
      // Paused users must never be resumed just to display the new rendition.
      try {
        await player.setVolume(0);
        await player.setRate(_effectiveRate);
        await player.prepareFirstFrame();
      } catch (error) {
        if (identical(_preparingPlayer, player)) _preparingPlayer = null;
        await player.dispose();
        if (mounted && reqId == _requestId) _failLoading('创建播放器失败: $error');
        return;
      }
    } else {
      unawaited(player.play());
      unawaited(player.setRate(_effectiveRate));
      if (initialSeekMs != null && initialSeekMs > 0) {
        unawaited(player.seek(Duration(milliseconds: initialSeekMs)));
      }
    }

    // 等首帧渲染出来再隐藏 loading（避免黑屏闪烁）
    try {
      await player.waitForFirstFrame();
      trace('first_frame');
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

    if (qualitySwitch != null) {
      if (!_qualitySwitches.isCurrent(qualitySwitch)) {
        unawaited(player.dispose());
        return;
      }
      try {
        await player.setRate(_effectiveRate);
        await player.setVolume(1);
        if (qualitySwitch.wantsPlaying &&
            !_userPaused &&
            !_pausedByRoute &&
            !_pausedByLifecycle &&
            !_sleepStopped) {
          await player.play();
        } else {
          await player.pause();
        }
      } catch (error) {
        if (identical(_preparingPlayer, player)) _preparingPlayer = null;
        await player.dispose();
        if (mounted && reqId == _requestId) _failLoading('切换清晰度失败: $error');
        return;
      }
      if (!mounted || reqId != _requestId) {
        unawaited(player.dispose());
        return;
      }
    }
    if (identical(_preparingPlayer, player)) _preparingPlayer = null;
    _player = player;
    _playerInitialized = true;
    _loading = false;
    _showNextLoading = false;
    positionMsNotifier.value = qualitySwitch?.position.inMilliseconds ??
        player.position.inMilliseconds;
    durationMsNotifier.value = player.duration.inMilliseconds;
    playingNotifier.value = qualitySwitch == null ? true : player.wantsPlaying;
    _refresh();

    _updateStep('player', StepStatus.success);
    _onEpisodeStarted(player, reqId, initialSeekMs);
  }

  /// 3-Player 窗口：切到相邻集且那一集已准备好时，交换引用直接复用；
  /// 否则释放整个窗口，返回 null 走新建路径。
  void _parkWindowPlayer(NativePlayer player) {
    unawaited(player.transition(() async {
      await player.setVolume(0);
      await player.pause();
      await player.setActive(false);
    }).catchError((Object error) {
      debugPrint('[PlaybackSDK] 停放播放器失败: $error');
    }));
  }

  NativePlayer? _takeWindowPlayer(int index, int direction) {
    if (direction == 1 &&
        nextPlayer != null &&
        nextEpisodeIndex == index &&
        nextPlayerReady) {
      final reused = preparedPlayers.take(engineKey(index));
      if (identical(reused, nextPlayer) && reused != null) {
        if (_player != null) {
          _parkWindowPlayer(_player!);
          if (prevPlayer != null) enqueueDispose(prevPlayer!);
          prevPlayer = _player;
          prevEpisodeIndex = index - 1;
          prevPositionMs = _player!.position.inMilliseconds;
          preparedPlayers.remember(engineKey(index - 1), _player!);
        }
        nextPlayer = null;
        nextEpisodeIndex = null;
        nextPlayerReady = false;
        return reused;
      }
    }
    if (direction == -1 && prevPlayer != null && prevEpisodeIndex == index) {
      final reused = preparedPlayers.take(engineKey(index));
      if (identical(reused, prevPlayer) && reused != null) {
        if (_player != null) {
          _parkWindowPlayer(_player!);
          if (nextPlayer != null) enqueueDispose(nextPlayer!);
          nextPlayer = _player;
          nextEpisodeIndex = index + 1;
          nextPlayerReady = _player!.isReusable;
          preparedPlayers.remember(engineKey(index + 1), _player!);
        }
        prevPlayer = null;
        prevEpisodeIndex = null;
        prevPositionMs = null;
        return reused;
      }
    }
    if (_player != null) {
      // Stop outgoing audio immediately even if another engine is still in
      // the asynchronous disposal queue.
      _parkWindowPlayer(_player!);
      enqueueDispose(_player!);
    }
    _player = null;
    dispose3PWindow();
    return null;
  }

  Future<bool> _activateReusedPlayer(
      NativePlayer reusedPlayer, int reqId, int? initialSeekMs) async {
    final token = PlaybackCancellation();
    playbackActivation = token;
    _player = reusedPlayer;
    final seekMs = initialSeekMs != null && initialSeekMs > 0
        ? initialSeekMs
        : (reusedPlayer.completed ? 0 : null);
    try {
      await reusedPlayer.transition(() => activatePreparedPlayback(
            cancellation: token,
            activate: () => reusedPlayer.setActive(true),
            position: () async {
              if (seekMs != null) {
                await reusedPlayer.seek(Duration(milliseconds: seekMs));
              }
            },
            rate: () => reusedPlayer.setRate(_effectiveRate),
            unmute: () => reusedPlayer.setVolume(1),
            play: reusedPlayer.play,
          ));
      token.check();
      if (!mounted || reqId != _requestId) return true;
      if (!reusedPlayer.isReusable) throw StateError('预渲染播放器已失效');
      _playerInitialized = true;
      _loading = false;
      _showNextLoading = false;
      positionMsNotifier.value = seekMs ?? reusedPlayer.position.inMilliseconds;
      durationMsNotifier.value = reusedPlayer.duration.inMilliseconds;
      playingNotifier.value = true;
      _refresh();
      _onEpisodeStarted(reusedPlayer, reqId, initialSeekMs);
      return true;
    } on PlaybackCancelled {
      // The newer switch/route/lifecycle owns the engine now.
      return true;
    } catch (error) {
      if (!mounted || reqId != _requestId) return true;
      debugPrint('[PlaybackSDK] 复用失败，重新创建播放器: $error');
      if (identical(_player, reusedPlayer)) _player = null;
      enqueueDispose(reusedPlayer);
      return false;
    } finally {
      if (identical(playbackActivation, token)) playbackActivation = null;
    }
  }

  /// 新的一集开始播放后的公共收尾：订阅、弹幕、预热、预取下一季、记历史。
  void _onEpisodeStarted(NativePlayer player, int reqId, int? initialSeekMs) {
    _startupPositionMs = initialSeekMs ?? player.position.inMilliseconds;
    _setupSubscriptions(player, reqId);
    if (_isDirectVideo) return;
    startPlaybackSession(_currentEpisodeIndex);
    _updatePlaybackScheduling();
    _danmakuController.clearComments();
    _loadDanmaku(positionMs: initialSeekMs);
    _saveHistory(positionMs: initialSeekMs);
  }

  /// 解析本集的播放源。离线播放读本地文件；`crypto://<cdn>?key=<hex>`
  /// 拆成 CDN 地址与密钥；格式不对时返回 null。
  Future<({String cdnUrl, String keyHex})?> _resolveSource(
      String videoId, int index, int reqId) async {
    if (_isDirectVideo) return (cdnUrl: videoId, keyHex: '');
    final localPath = cachedEpisodePath(index);
    if (localPath != null) {
      return (
        cdnUrl: await OfflinePlaybackCache.playableFileUri(localPath),
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
      cancelPlaybackPreparation();
      _bufferMonitor?.stop();
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
      _updatePlaybackScheduling();
    });
    _completedSub = player.completedStream.listen((completed) {
      if (reqId != _requestId) return;
      if (completed) _onAutoNext();
    });
    _bufferingSub = player.bufferingStream.listen((_) {
      if (!mounted || reqId != _requestId) return;
      _updatePlaybackScheduling();
    });
    _bufferedAheadSub = player.bufferedAheadStream.listen((_) {
      if (!mounted || reqId != _requestId) return;
      _updatePlaybackScheduling();
    });
    _playbackIntentSub = player.playbackIntentStream.listen((_) {
      if (!mounted || reqId != _requestId) return;
      _updatePlaybackScheduling();
    });
    _bufferMonitor = PlaybackBufferMonitor(
      read: player.pollBufferState,
      onSample: () {
        if (mounted && reqId == _requestId && identical(player, _player)) {
          _updatePlaybackScheduling();
        }
      },
      onError: (error, _) => debugPrint('[PlaybackSDK] 缓冲状态读取失败: $error'),
    );
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
    _bufferingSub?.cancel();
    _bufferedAheadSub?.cancel();
    _playbackIntentSub?.cancel();
    _bufferMonitor?.stop();
    _bufferMonitor = null;
  }

  void _checkPreloadThresholds(Duration position, Duration duration) {
    if (_isDirectVideo) return;
    _updatePlaybackScheduling();
    if (duration <= Duration.zero) return;
    // 持续加载弹幕下一批
    unawaited(_danmakuController.ensureLoadedUpTo(
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      isTheaterResource: _drama.isTheaterResource,
      isOfflinePlayback: isOfflinePlayback,
    ));
  }

  void _updatePlaybackScheduling() {
    final player = _player;
    if (_isDirectVideo || player == null || !_playerInitialized) return;
    final ahead = player.bufferedAhead;
    final local = cachedEpisodePath(_currentEpisodeIndex) != null;
    final active = player.wantsPlaying &&
        !player.completed &&
        _seekingPositionMs == null &&
        !_pausedByRoute &&
        !_pausedByLifecycle &&
        !_userPaused &&
        !_sleepStopped;
    if (active) {
      _bufferMonitor?.start();
    } else {
      _bufferMonitor?.stop();
    }
    playbackSession.update(
      firstFrame: player.firstFrameRendered,
      buffering: player.buffering,
      active: active,
      played: Duration(
          milliseconds: (player.position.inMilliseconds - _startupPositionMs)
              .clamp(0, 1 << 31)),
      bufferedAhead: ahead,
      fullyBuffered: local,
      position: player.position,
      duration: player.duration,
    );
    // Season metadata is small, but still follows the current playback's
    // health rather than a fixed percentage of the episode.
    if (playbackSession.canPreloadNetwork) {
      _maybePrefetchNextSeason();
    }
  }

  // ─── 自动下一集 ────────────────────────────────────────────────────────

  void _onAutoNext() {
    if (_isDirectVideo) {
      _userPaused = true;
      _refresh();
      return;
    }
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
    if (_isDirectVideo) return;
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
