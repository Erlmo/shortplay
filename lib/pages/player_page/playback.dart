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

    _retiredIndex = _currentEpisodeIndex;
    final direction = index - _currentEpisodeIndex;
    // 预渲染跟着滑动方向走：往回滑就准备上一集。跳集、切清晰度时保持原方向。
    if (direction == 1 || direction == -1) swipeDirection = direction;
    _currentEpisodeIndex = index;
    _cancelPlayerSubscriptions();

    final reusedPlayer = _takeStandbyPlayer(index);
    debugPrint(reusedPlayer != null
        ? '[Playback] 直接接管已就绪的播放器：第${index + 1}集'
        : '[Playback] 未命中预渲染，新建播放器：第${index + 1}集');
    if (reusedPlayer != null) {
      if (await _activateReusedPlayer(reusedPlayer, reqId, initialSeekMs)) {
        return;
      }
      if (!mounted || reqId != _requestId) return;
    }

    // 新建播放器路径
    // 回到看过的集（停放的播放器已释放）时，从记住的进度接着播。
    if (initialSeekMs == null && qualitySwitch == null) {
      initialSeekMs = resumePositionOf(index);
    }
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

    // 从头播放网络视频时，先用一次请求把开头 512KB 下到本地缓存（提前下载已在进行就直接合并进去），
    // 播放器起播时直接读本地，不再一来一回地分几次小请求读文件头。最多等 2 秒，超时就照常起播。
    if ((initialSeekMs == null || initialSeekMs <= 0) &&
        !_isDirectVideo &&
        cachedEpisodePath(index) == null) {
      try {
        await _preloadManager
            .prefetchMedia(videoId, PlaybackCancellation(), bytes: 512 * 1024)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // 预取失败或超时不影响起播。
      }
      if (!mounted || reqId != _requestId) return;
      trace('head_prefetched');
    }
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
      // 续播直接从记住的位置创建：不先从头加载再跳转，省掉开头那段白下的数据和一次跳转。
      await player.create(cdnUrl, keyHex,
          initialPositionMs: initialSeekMs != null && initialSeekMs > 0
              ? initialSeekMs
              : null);
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
    }

    // 等首帧渲染出来再隐藏 loading（避免黑屏闪烁）
    try {
      await player.waitForFirstFrame();
      trace('first_frame');
      debugPrint('[Playback] 第${index + 1}集新建播放器出画耗时 '
          '${startup.elapsedMilliseconds}ms');
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

  /// 切到第 [index] 集：命中预渲染或停放的上一集就直接接管；当前播放器停声后停放。
  /// 预渲染的不是这一集（例如反方向滑动或跳集）时释放它，之后按新方向重新准备。
  NativePlayer? _takeStandbyPlayer(int index) {
    final fromStandby = takeStandby(index);
    final reused = fromStandby ?? takeParked(index);
    if (fromStandby == null && reused != null) {
      debugPrint('[Playback] 接管停放的上一集：第${index + 1}集，原位置继续');
    }
    // 换下来的当前集停放成「上一集」，往回滑时可以原位接着播。
    if (_player != null) parkPlayer(_player!, _retiredIndex);
    _player = null;
    if (fromStandby == null && standbyIndex != index) discardStandby();
    return reused;
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
    _setupSubscriptions(player, reqId);
    if (_isDirectVideo) return;
    startPreparation(_currentEpisodeIndex);
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
    return CryptoNativeChannel.splitCryptoUrl(url);
  }

  // ─── 订阅 ──────────────────────────────────────────────────────────────

  void _setupSubscriptions(NativePlayer player, int reqId) {
    _errorSub = player.errorStream.listen((message) {
      if (!mounted || reqId != _requestId) return;
      cancelPlaybackPreparation();
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

  /// 播放状态变化时推进后台准备：预渲染相邻集、预下载后面几集；当前集卡顿时暂停这些网络任务。
  void _updatePlaybackScheduling() {
    final player = _player;
    if (_isDirectVideo || player == null || !_playerInitialized) return;
    schedulePreparation();
    // 到了本季最后一集：预取下一季目录和首集（同样排在预加载队列里，受卡顿保护）。
    _maybePrefetchNextSeason();
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
        videoId: _episodes[_currentEpisodeIndex].url.trim(),
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
    cancelPlaybackPreparation();
    discardStandby();
    playingNotifier.value = false;
    _screenAwake.release();
    _systemUi.showUIAndResetTimer();
    _refresh(() {
      _playerInitialized = false;
      _loading = false;
      _showNextLoading = false;
      _errorMessage = null;
    });
    showAppNotice(context,
        message: '定时已结束',
        detail: '播放已停止，点击播放按钮可继续',
        kind: AppNoticeKind.info,
        abovePlayerControls: true);
  }
}
