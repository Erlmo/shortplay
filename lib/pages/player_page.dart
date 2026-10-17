import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../models/drama_season.dart';
import '../models/episode.dart';
import '../models/workflow_step.dart';
import '../services/api_client.dart';
import '../models/playback_record.dart';
import '../services/app_route_observer.dart';
import '../services/download_service.dart';
import '../services/crypto_native_channel.dart';
import '../services/device_profile.dart';
import '../services/native_player.dart';
import '../services/offline_playback_cache.dart';
import '../services/playback_history_store.dart';
import '../services/player_danmaku_controller.dart';
import '../services/player_system_ui_controller.dart';
import '../services/player_sleep_timer.dart';
import '../services/theater_video_preload_manager.dart';
import '../widgets/player/episode_sheet.dart';
import '../widgets/player/hg_episode_panel.dart';
import '../widgets/player/player_controls_overlay.dart';
import '../widgets/player/player_loading.dart';
import '../widgets/player/player_more_menu.dart';
import '../widgets/player/player_video_surface.dart';
import '../widgets/app_notice.dart';
import '../widgets/danmaku_layer.dart';
import 'player_preload_mixin.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.drama,
    required this.apiClient,
    this.downloadService,
    this.initialEpisodeIndex,
    this.initialEpisodeNumber,
    this.initialPositionMs,
    this.offlineEpisodes,
    this.prefetchedEpisodes,
    this.preloadManager,
  });

  final Drama drama;
  final ApiClient apiClient;
  final DownloadService? downloadService;
  final int? initialEpisodeIndex;
  final int? initialEpisodeNumber;
  final int? initialPositionMs;
  final List<Episode>? offlineEpisodes;
  final Future<TheaterEpisodesResult>? prefetchedEpisodes;
  final TheaterVideoPreloadManager? preloadManager;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with
        PlayerPreloadMixin,
        WidgetsBindingObserver,
        RouteAware,
        SingleTickerProviderStateMixin {
  // 红果：竖屏打开选集面板时，画面缩到面板上方（0 = 全屏，1 = 缩小）
  late final AnimationController _episodeShrink;

  /// 当前缩放目标对应的底部面板高度（选集面板 = 屏高 50%，“…”面板按实测高度）
  double? _shrinkPanelHeight;

  void _onBottomPanelHeight(double height) {
    if (DeviceProfile.isTv) return;
    if (height <= 0) {
      unawaited(_episodeShrink.reverse());
      return;
    }
    if (!PlayerVideoSurface.usesPhoneLayout(
        MediaQuery.of(context).size, _systemUi.isLandscapeFullScreen)) {
      return;
    }
    setState(() => _shrinkPanelHeight = height);
    unawaited(_episodeShrink.forward());
  }

  Drama? _selectedSeasonDrama;
  Drama get _drama => _selectedSeasonDrama ?? widget.drama;

  NativePlayer? _player;
  NativePlayer? _preparingPlayer;
  StreamSubscription<String>? _errorSub;
  bool _sleepStopped = false;
  int _sleepPositionMs = 0;
  bool _actionSheetOpen = false;
  bool _playerInitialized = false;
  int _currentEpisodeIndex = 0;
  int _requestId = 0;
  int _catalogRequestId = 0;

  bool _programmaticJump = false;
  bool _loading = true;
  String? _errorMessage;
  bool _showNextLoading = false;
  bool _swipeBlocked = false;
  Timer? _swipeBlockTimer;
  bool _userPaused = false;
  bool _landscapeFill = false;

  // ─── 遥控器 / 键盘 ─────────────────────────────────────────────────────
  final FocusNode _keyFocus = FocusNode(debugLabel: 'player-keys');
  bool _showKeyHint = false;
  Timer? _keyHintTimer;
  // 长按 OK 呼出菜单：按下时起计时，松开前到点就打开菜单，否则当作单击暂停
  Timer? _okHoldTimer;
  bool _pausedByLifecycle = false;
  // 本页被新路由（如再次打开的播放页）覆盖时暂停，新路由弹出回到本页时恢复，
  // 与 _pausedByLifecycle 分开记，避免两套恢复逻辑互相误触发。
  bool _pausedByRoute = false;
  bool _isSpeedUp = false;
  int _activePointers = 0;
  double _playbackSpeed = 1.0;
  int? _sleepTimerMinutes;
  double? _seekingPositionMs;
  final String _loadingStatusText = '正在准备播放资源';
  List<WorkflowStep> _steps = const [
    WorkflowStep(id: 'episodes', label: '获取剧集列表', status: StepStatus.running),
    WorkflowStep(id: 'resolve', label: '解析播放地址'),
    WorkflowStep(id: 'player', label: '初始化播放器'),
  ];

  final positionMsNotifier = ValueNotifier<int>(0);
  final playingNotifier = ValueNotifier<bool>(false);
  final durationMsNotifier = ValueNotifier<int>(0);
  final speedButtonKey = GlobalKey();

  List<Episode> _episodes = const [];

  late final PlayerSystemUiController _systemUi;
  late final PlayerSleepTimer _sleepTimer;
  late final PlayerDanmakuController _danmakuController;
  int _danmakuSeekGeneration = 0;
  late final TheaterVideoPreloadManager _preloadManager;
  PageController? _pageController;

  bool _didPreloadN2 = false;
  bool _didPreloadN3 = false;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;

  @override
  List<Episode> get episodes => _episodes;
  @override
  TheaterVideoPreloadManager get preloadManager => _preloadManager;
  @override
  bool get isOfflinePlayback => widget.offlineEpisodes != null;

  // ─── 生命周期 ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _episodeShrink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    WidgetsBinding.instance.addObserver(this);
    _systemUi = PlayerSystemUiController();
    _systemUi.addListener(_onSystemUiChanged);
    _sleepTimer = PlayerSleepTimer(onElapsed: _stopForSleep);
    _sleepTimer.addListener(_onSystemUiChanged);
    _preloadManager = widget.preloadManager ??
        TheaterVideoPreloadManager(apiClient: widget.apiClient);
    _danmakuController = PlayerDanmakuController(apiClient: widget.apiClient);
    _currentEpisodeIndex = widget.initialEpisodeIndex ?? 0;
    unawaited(_systemUi.setFullScreen());
    NativePlayer.setKeepScreenOn(true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _flashKeyHint());
    _prepare();
  }

  void _onSystemUiChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅路由覆盖事件。ModalRoute 在此处才可用。
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      appRouteObserver.subscribe(this, route);
    }
  }

  // 本页之上 push 了新路由（例如又识别剪贴板打开了新的播放页）：暂停，
  // 否则旧播放器会在后面继续出声，与新页音频叠加。
  @override
  void didPushNext() {
    if (_player != null && playingNotifier.value && !_userPaused) {
      _pausedByRoute = true;
      _player!.pause();
    }
  }

  // 上层路由弹出、本页重新可见：恢复之前因覆盖而暂停的播放。
  @override
  void didPopNext() {
    _sleepTimer.checkDeadline();
    if (_sleepStopped) return;
    if (_pausedByRoute) {
      _pausedByRoute = false;
      // 用户未手动暂停、也不是被生命周期暂停时才自动续播。
      if (!_userPaused && !_pausedByLifecycle) _player?.play();
    }
  }

  @override
  void dispose() {
    _episodeShrink.dispose();
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    NativePlayer.setKeepScreenOn(false);
    _swipeBlockTimer?.cancel();
    _keyHintTimer?.cancel();
    _okHoldTimer?.cancel();
    _keyFocus.dispose();
    _systemUi.removeListener(_onSystemUiChanged);
    _sleepTimer.removeListener(_onSystemUiChanged);
    _sleepTimer.dispose();
    if (_preparingPlayer != null) enqueueDispose(_preparingPlayer!);
    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    if (_player != null) enqueueDispose(_player!);
    dispose3PWindow();
    _systemUi.exitFullScreen();
    _systemUi.dispose();
    _danmakuController.dispose();
    positionMsNotifier.dispose();
    playingNotifier.dispose();
    durationMsNotifier.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_player != null && playingNotifier.value && !_userPaused) {
        _pausedByLifecycle = true;
        _player!.pause();
      }
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_systemUi.reapplyBottomBar());
      _sleepTimer.checkDeadline();
      if (_sleepStopped) return;
      if (_pausedByLifecycle && !_userPaused) {
        _pausedByLifecycle = false;
        _player?.play();
      }
    }
  }

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
    setState(() {});

    try {
      if (widget.offlineEpisodes != null) {
        _episodes = widget.offlineEpisodes!;
      } else if (_selectedSeasonDrama == null &&
          widget.prefetchedEpisodes != null) {
        final result = await widget.prefetchedEpisodes!;
        if (!mounted || catalogRequest != _catalogRequestId) return;
        _episodes = result.toEpisodes();
      } else {
        final result =
            await widget.apiClient.fetchTheaterEpisodes(_drama.id.toString());
        if (!mounted || catalogRequest != _catalogRequestId) return;
        _episodes = result.toEpisodes();
      }

      if (!mounted || catalogRequest != _catalogRequestId) return;
      _updateStep('episodes', StepStatus.success);
      _updateStep('resolve', StepStatus.running);

      if (_episodes.isEmpty) {
        setState(() {
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
      setState(() {
        _loading = false;
        _errorMessage = '加载失败: $e';
      });
    }
  }

  void _updateStep(String id, StepStatus status) {
    _steps =
        _steps.map((s) => s.id == id ? s.copyWith(status: status) : s).toList();
    if (mounted) setState(() {});
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

    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();

    NativePlayer? reusedPlayer;

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
      reusedPlayer = nextPlayer;
      nextPlayer = null;
      nextEpisodeIndex = null;
      nextPlayerReady = false;
    } else if (direction < 0 &&
        prevPlayer != null &&
        prevEpisodeIndex == index) {
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
      reusedPlayer = prevPlayer;
      prevPlayer = null;
      prevEpisodeIndex = null;
      prevPositionMs = null;
    } else {
      if (_player != null) {
        unawaited(_player!.pause());
        enqueueDispose(_player!);
      }
      dispose3PWindow();
    }

    if (reusedPlayer != null) {
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
      setState(() {});
      // 升为当前集：恢复正常预读
      unawaited(reusedPlayer.setActive(true));
      unawaited(reusedPlayer.setVolume(1.0));
      unawaited(reusedPlayer.setRate(_isSpeedUp ? 2.0 : _playbackSpeed));
      unawaited(reusedPlayer.play());
      if (initialSeekMs != null && initialSeekMs > 0) {
        unawaited(reusedPlayer.seek(Duration(milliseconds: initialSeekMs)));
      }
      _setupSubscriptions(reusedPlayer, reqId);
      _danmakuController.clearComments();
      _loadDanmaku(positionMs: initialSeekMs);
      schedulePreloads(_currentEpisodeIndex);
      _saveHistory();
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
    setState(() {
      _loading = true;
      _playerInitialized = false;
    });

    final episode = _episodes[index];
    final videoId = episode.url.trim();
    if (videoId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '视频地址为空';
      });
      return;
    }

    String cdnUrl;
    String keyHex;

    try {
      if (isOfflinePlayback) {
        cdnUrl = await OfflinePlaybackCache.playableFileUri(videoId);
        keyHex = '';
      } else {
        final url = await _preloadManager.resolvePlayUrl(
          videoId,
          episodeIndex: index,
        );
        if (!mounted || reqId != _requestId) return;

        if (!url.startsWith('crypto://')) {
          cdnUrl = url;
          keyHex = '';
        } else {
          final encoded = url.substring('crypto://'.length);
          final qIdx = encoded.indexOf('?key=');
          if (qIdx < 0) {
            setState(() {
              _loading = false;
              _errorMessage = '无效的播放地址';
            });
            return;
          }
          cdnUrl = Uri.decodeComponent(encoded.substring(0, qIdx));
          keyHex = encoded.substring(qIdx + 5);
        }
      }
    } catch (e) {
      if (!mounted || reqId != _requestId) return;
      setState(() {
        _loading = false;
        _errorMessage = '$_resolveStepLabel失败: $e';
      });
      return;
    }

    if (!mounted || reqId != _requestId) return;
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
      setState(() {
        _loading = false;
        _errorMessage = '创建播放器失败: $e';
      });
      return;
    }

    if (!mounted || reqId != _requestId) {
      unawaited(player.dispose());
      return;
    }

    // 先 play，让 AVPlayer 开始缓冲和解码
    unawaited(player.play());
    unawaited(player.setRate(_isSpeedUp ? 2.0 : _playbackSpeed));
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
      setState(() {
        _loading = false;
        _errorMessage =
            error is TimeoutException ? '视频加载超时，请重试' : '播放失败: $error';
      });
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
    setState(() {});

    _updateStep('player', StepStatus.success);
    _setupSubscriptions(player, reqId);
    _danmakuController.clearComments();
    _loadDanmaku(positionMs: initialSeekMs);
    schedulePreloads(_currentEpisodeIndex);
    _saveHistory();
  }

  // ─── 订阅 ──────────────────────────────────────────────────────────────

  void _setupSubscriptions(NativePlayer player, int reqId) {
    _errorSub = player.errorStream.listen((message) {
      if (!mounted || reqId != _requestId) return;
      setState(() {
        _loading = false;
        _errorMessage = '播放失败: $message';
      });
    });
    _positionSub = player.positionStream.listen((pos) {
      if (reqId != _requestId) return;
      positionMsNotifier.value = pos.inMilliseconds;
      _checkPreloadThresholds(pos, player.duration);
    });
    _playingSub = player.playingStream.listen((playing) {
      if (reqId != _requestId) return;
      playingNotifier.value = playing;
    });
    _completedSub = player.completedStream.listen((completed) {
      if (reqId != _requestId) return;
      if (completed) _onAutoNext();
    });
    player.durationStream.listen((dur) {
      if (reqId != _requestId) return;
      durationMsNotifier.value = dur.inMilliseconds;
    });
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
    if (next >= _episodes.length) return;
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

  void _saveHistory() {
    final drama = _drama;
    final posMs = _player?.position.inMilliseconds ?? 0;
    unawaited(
      PlaybackHistoryStore.upsert(PlaybackRecord(
        dramaId: drama.id,
        dramaName: drama.name,
        cover: drama.cover,
        episodeIndex: _currentEpisodeIndex,
        positionMs: posMs,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      )),
    );
  }

  // ─── 操作回调 ──────────────────────────────────────────────────────────

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
    } else {
      _userPaused = false;
      unawaited(player.play());
    }
    setState(() {});
  }

  bool _resumeAfterSeek = false;

  void _onSeekStart(double ms) {
    final player = _player;
    if (player == null || !_playerInitialized) return;
    _resumeAfterSeek = player.playing;
    player.pause();
    setState(() => _seekingPositionMs = ms);
  }

  // 拖动时刷新屏幕中间的大号时间
  void _onSeekChanged(double ms) {
    setState(() => _seekingPositionMs = ms);
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
        if (mounted) setState(() => _seekingPositionMs = null);
      });
    } else {
      setState(() => _seekingPositionMs = null);
    }
  }

  void _onSpeedTap() {
    const speeds = [1.0, 1.25, 1.5, 2.0];
    final idx = speeds.indexOf(_playbackSpeed);
    final next = speeds[(idx + 1) % speeds.length];
    _playbackSpeed = next;
    if (_player != null && _playerInitialized) {
      unawaited(_player!.setRate(_playbackSpeed));
    }
    setState(() {});
  }

  void _onSpeedChanged(double value) {
    _playbackSpeed = value;
    if (_player != null && _playerInitialized) {
      unawaited(_player!.setRate(value));
    }
    setState(() {});
  }

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
    if (_episodes.isNotEmpty && !isOfflinePlayback) {
      unawaited(_openEpisode(_currentEpisodeIndex,
          initialSeekMs: positionMsNotifier.value));
    }
    setState(() {});
  }

  void _onSleepDurationChanged(Duration? duration) {
    _sleepTimerMinutes = duration == null || duration == Duration.zero
        ? null
        : duration.inMinutes;
    if (duration == null || duration == Duration.zero) {
      _sleepTimer.cancel();
    } else {
      _sleepTimer.start(duration);
    }
    setState(() {});
  }

  void _onLongPressStart(LongPressStartDetails _) {
    _isSpeedUp = true;
    if (_player != null && _playerInitialized) {
      unawaited(_player!.setRate(2.0));
    }
    setState(() {});
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    if (_activePointers > 0) return;
    _isSpeedUp = false;
    if (_player != null && _playerInitialized) {
      unawaited(_player!.setRate(_playbackSpeed));
    }
    setState(() {});
  }

  void _endSpeedUp() {
    if (!_isSpeedUp) return;
    _isSpeedUp = false;
    if (_player != null && _playerInitialized) {
      unawaited(_player!.setRate(_playbackSpeed));
    }
    setState(() {});
  }

  void _onToggleDanmaku() {
    unawaited(_danmakuController.toggle(
      isOfflinePlayback: isOfflinePlayback,
      currentEpisode:
          _episodes.isNotEmpty ? _episodes[_currentEpisodeIndex] : null,
      bookId: _drama.id.toString(),
      durationMs: durationMsNotifier.value,
      positionMs: positionMsNotifier.value,
    ));
    setState(() {});
  }

  void _loadDanmaku({int? positionMs}) {
    if (isOfflinePlayback || !_drama.isTheaterResource) return;
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
    _danmakuSeekGeneration++;
    unawaited(_danmakuController.ensureLoadedUpTo(
      positionMs: positionMs,
      durationMs: durationMsNotifier.value,
      seek: true,
      isTheaterResource: _drama.isTheaterResource,
      isOfflinePlayback: isOfflinePlayback,
    ));
  }

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

  // 遥控器/键盘：上下切集，左右快退/快进 10 秒，OK/回车/空格 暂停播放，
  // 长按 OK 或菜单键（M）打开播放菜单（选集/倍速/清晰度/定时/弹幕/下载），
  // E 直接打开选集。电视返回键先隐藏屏显，再退出播放页。
  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };

  KeyEventResult _onPlayerKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_okKeys.contains(key)) {
      if (event is KeyDownEvent) {
        _okHoldTimer?.cancel();
        _okHoldTimer = Timer(const Duration(milliseconds: 600), () {
          _okHoldTimer = null;
          unawaited(_openMoreMenu());
        });
      } else if (event is KeyRepeatEvent) {
        // 系统按住约 0.5 秒后开始发重复事件：这就是长按，立即打开菜单
        if (_okHoldTimer != null) {
          _okHoldTimer!.cancel();
          _okHoldTimer = null;
          unawaited(_openMoreMenu());
        }
      } else if (event is KeyUpEvent) {
        if (_okHoldTimer != null) {
          _okHoldTimer!.cancel();
          _okHoldTimer = null;
          _systemUi.showUIAndResetTimer();
          _onTogglePlay();
        }
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isDown = event is KeyDownEvent;
    if (key == LogicalKeyboardKey.escape && DeviceProfile.isTv) {
      if (isDown) _onBack();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.pageUp) {
      if (isDown) _stepEpisode(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.pageDown) {
      if (isDown) _stepEpisode(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-10000);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(10000);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (isDown) _onTogglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      final wantPlay = key == LogicalKeyboardKey.mediaPlay;
      if (isDown && playingNotifier.value != wantPlay) _onTogglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.info ||
        key == LogicalKeyboardKey.keyM) {
      if (isDown) unawaited(_openMoreMenu());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE) {
      if (isDown) unawaited(_onEpisodeTap());
      return KeyEventResult.handled;
    }
    // F：横屏全屏 / 退出（桌面键盘、外接键盘）
    if (key == LogicalKeyboardKey.keyF && !DeviceProfile.isTv) {
      if (isDown) _onToggleLandscapeFullScreen();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _stepEpisode(int delta) {
    final target = _currentEpisodeIndex + delta;
    if (target < 0 || target >= _episodes.length) return;
    _systemUi.showUIAndResetTimer();
    _jumpToEpisode(target);
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
    setState(() {});
  }

  void _flashKeyHint() {
    if (!DeviceProfile.isTv) return;
    setState(() => _showKeyHint = true);
    _keyHintTimer?.cancel();
    _keyHintTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showKeyHint = false);
    });
  }

  Widget _buildKeyHint() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 96,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(170),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Text(
              '↑↓ 切集   ←→ 快退/快进   OK 暂停   长按 OK / 菜单键 选集·倍速·清晰度',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }

  bool _moreMenuOpen = false;

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
        canDownload: widget.downloadService != null &&
            !isOfflinePlayback &&
            _drama.isTheaterResource,
        isOfflinePlayback: isOfflinePlayback,
        sleepTimerActive: _sleepTimer.isActive,
        danmakuEnabled: _danmakuController.enabled,
        playbackSpeed: _playbackSpeed,
        currentQuality:
            isOfflinePlayback ? '' : _preloadManager.selectedDefinition(url),
        loadQualities: isOfflinePlayback
            ? null
            : () => _preloadManager.availableDefinitions(url),
        onToggleDanmaku: _onToggleDanmaku,
        onSpeedChanged: _onSpeedChanged,
        onQualityChanged: _onQualityChanged,
        onSleepDurationChanged: _onSleepDurationChanged,
        sleepTimerMinutes: _sleepTimer.isActive ? _sleepTimerMinutes : null,
        showEpisodes: true,
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
    DramaSeason? selectedSeason;
    final episodeNotifier = ValueNotifier<int>(_currentEpisodeIndex);
    _systemUi.setMenuOpen(true);
    _shrinkPanelHeight = null; // 选集面板：屏高 50%
    final shrink = !DeviceProfile.isTv &&
        PlayerVideoSurface.usesPhoneLayout(
            MediaQuery.of(context).size, _systemUi.isLandscapeFullScreen);
    if (shrink) unawaited(_episodeShrink.forward());
    final status = _drama.status.trim();
    try {
      await showPlayerEpisodeSheet(
        context: context,
        isLandscapeFullScreen: _systemUi.isLandscapeFullScreen,
        dramaName: _drama.name,
        episodes: _episodes,
        currentDramaId: _drama.id,
        loadSeasons: _drama.isTheaterResource && !isOfflinePlayback
            ? () => widget.apiClient.fetchDramaSeasons(_drama.id.toString())
            : null,
        onSelectSeason: (season) => selectedSeason = season,
        loadTitles: _drama.isTheaterResource && !isOfflinePlayback
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

  Future<void> _switchSeason(DramaSeason season) async {
    if (!mounted || isOfflinePlayback || season.id == _drama.id) return;
    if (_playerInitialized) _saveHistory();
    ++_requestId;
    ++_catalogRequestId;
    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    final oldPlayer = _player;
    final preparingPlayer = _preparingPlayer;
    _player = null;
    _preparingPlayer = null;
    dispose3PWindow();
    _preloadManager.clear();
    _danmakuController.clearComments();
    _swipeBlockTimer?.cancel();
    _pageController?.dispose();
    _pageController = null;
    positionMsNotifier.value = 0;
    durationMsNotifier.value = 0;
    playingNotifier.value = false;
    setState(() {
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

  Future<void> _onMenuAction(PlayerMenuAction action) async {
    if (_actionSheetOpen) return;
    _actionSheetOpen = true;
    _systemUi.setMenuOpen(true);
    try {
      switch (action) {
        case PlayerMenuAction.episodes:
          break; // 由 _openMoreMenu 处理
        case PlayerMenuAction.download:
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
    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    if (_player != null) enqueueDispose(_player!);
    if (_preparingPlayer != null) enqueueDispose(_preparingPlayer!);
    _player = null;
    _preparingPlayer = null;
    dispose3PWindow();
    _swipeBlockTimer?.cancel();
    playingNotifier.value = false;
    unawaited(NativePlayer.setKeepScreenOn(false));
    _systemUi.showUIAndResetTimer();
    setState(() {
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

  void _onToggleLandscapeFullScreen() {
    _systemUi.toggleLandscapeFullScreen();
    setState(() {});
  }

  void _onToggleVideoFit() {
    setState(() => _landscapeFill = !_landscapeFill);
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

  void _onPageChanged(int index) {
    if (_sleepStopped) return;
    if (_programmaticJump) return;
    if (index == _currentEpisodeIndex) return;
    final isForward = index > _currentEpisodeIndex;

    // 向前滑且下一集没准备好：阻止翻页
    if (isForward && !nextPlayerReady && !_swipeBlocked) {
      // 弹回原位
      _programmaticJump = true;
      _pageController?.animateToPage(
        _currentEpisodeIndex,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
      _programmaticJump = false;

      // 显示胶囊提示 + 启动5秒超时
      setState(() => _swipeBlocked = true);
      _swipeBlockTimer?.cancel();
      _swipeBlockTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        // 超时后允许翻页，走新建路径
        setState(() => _swipeBlocked = false);
      });
      return;
    }

    // 正常翻页：新的一集会自动播放，清掉上一集的“用户已暂停”状态，
    // 否则中间的播放图标会一直挂着
    _swipeBlockTimer?.cancel();
    setState(() {
      _swipeBlocked = false;
      _userPaused = false;
    });
    unawaited(_openEpisode(index));
  }

  // ─── 构建 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // nextPlayerReady 变为 true 时自动清除 swipeBlocked
    if (nextPlayerReady && _swipeBlocked) {
      _swipeBlocked = false;
      _swipeBlockTimer?.cancel();
    }

    // 电视先关闭屏显；手机横屏全屏时先退回竖屏。
    return PopScope(
      canPop: !_systemUi.isLandscapeFullScreen &&
          !(DeviceProfile.isTv && _systemUi.showLandscapeUI),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _keyFocus,
          autofocus: true,
          onKeyEvent: _onPlayerKey,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _activePointers++,
            onPointerUp: (_) {
              _activePointers--;
              _endSpeedUp();
            },
            onPointerCancel: (_) {
              _activePointers--;
              _endSpeedUp();
            },
            child: Stack(
              children: [
                if (_pageController != null) _buildPageView(),
                if (_pageController != null && !DeviceProfile.usesFocusUi)
                  _buildBottomEdgeGuard(),
                if (_loading) _buildLoading(),
                if (!_loading && _errorMessage != null) _buildError(),
                if (_swipeBlocked) _buildSwipeBlockedHint(),
                if (_showNextLoading) _buildNextLoading(),
                if (_showKeyHint) _buildKeyHint(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageView() {
    // 下一集没准备好且不是最后一集时，阻止向前翻页
    final bool blockForward = !nextPlayerReady &&
        _currentEpisodeIndex < _episodes.length - 1 &&
        !_loading;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (!blockForward) return false;
        // 检测上滑（向前翻页）的 overscroll
        if (notification is OverscrollNotification &&
            notification.overscroll > 0) {
          // 显示胶囊提示
          if (!_swipeBlocked) {
            setState(() => _swipeBlocked = true);
            _swipeBlockTimer?.cancel();
            _swipeBlockTimer = Timer(const Duration(seconds: 5), () {
              if (!mounted) return;
              setState(() => _swipeBlocked = false);
            });
          }
        }
        return false;
      },
      child: PageView.builder(
        key: ValueKey('player-pages-${_drama.id}'),
        controller: _pageController,
        scrollDirection: Axis.vertical,
        physics: _sleepStopped
            ? const NeverScrollableScrollPhysics()
            : blockForward
                ? const _BlockForwardScrollPhysics()
                : const BouncingScrollPhysics(),
        onPageChanged: _onPageChanged,
        itemCount: _episodes.length,
        itemBuilder: (context, index) {
          return _buildEpisodePage(index);
        },
      ),
    );
  }

  NativePlayer? _pagePlayerFor(int index) {
    if (index == _currentEpisodeIndex) return _player;
    if (index == nextEpisodeIndex && nextPlayer != null) return nextPlayer;
    if (index == prevEpisodeIndex && prevPlayer != null) return prevPlayer;
    return null;
  }

  // 视频尺寸由原生异步上报：尺寸一到就重建这一页（画面缩放 + 横屏按钮），
  // 不等下一次无关的 setState，避免横屏片源先按 9:16 被拉伸一会儿。
  Widget _buildEpisodePage(int index) {
    final pagePlayer = _pagePlayerFor(index);
    if (pagePlayer == null) return _buildEpisodePageContent(index);
    return ValueListenableBuilder<Size>(
      valueListenable: pagePlayer.videoSizeNotifier,
      builder: (context, _, __) => _buildEpisodePageContent(index),
    );
  }

  /// 选集面板打开时把画面（竖屏可见区域）等比缩到面板上方、贴着状态栏下沿。
  Widget _shrinkable(Widget video, NativePlayer? player) {
    return AnimatedBuilder(
      animation: _episodeShrink,
      child: video,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_episodeShrink.value);
        if (t == 0) return child!;
        final media = MediaQuery.of(context);
        final size = media.size;
        final top = media.viewPadding.top;
        final fills = PlayerVideoSurface.usesPhoneLayout(size, false);
        // 竖屏时画面可见区域在底部选集栏之上
        final areaH = fills
            ? size.height - PlayerVideoSurface.phoneBottomBarHeight
            : size.height;
        final panelH =
            _shrinkPanelHeight ?? size.height * kHgEpisodePanelHeightFactor;
        final targetH = size.height - panelH - top - 8;
        final scale = (targetH / areaH).clamp(0.2, 1.0);
        final s = 1 - (1 - scale) * t;
        return Transform(
          alignment: Alignment.topCenter,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, top * t, 0.0, 1.0)
            ..scaleByDouble(s, s, 1.0, 1.0),
          child: child,
        );
      },
    );
  }

  /// 红果：选集面板打开时隐藏弹幕和控件，只留缩小的画面。
  Widget _hideWhileShrunk(Widget child) => AnimatedBuilder(
        animation: _episodeShrink,
        child: child,
        builder: (context, child) {
          final v = _episodeShrink.value;
          if (v == 0) return child!;
          return IgnorePointer(
            child: Opacity(opacity: (1 - v * 2).clamp(0.0, 1.0), child: child),
          );
        },
      );

  Widget _buildEpisodePageContent(int index) {
    final isActive = index == _currentEpisodeIndex;

    // 根据 index 决定使用哪个 player 的 texture
    NativePlayer? pagePlayer;
    if (isActive) {
      pagePlayer = _player;
    } else if (index == nextEpisodeIndex && nextPlayer != null) {
      pagePlayer = nextPlayer;
    } else if (index == prevEpisodeIndex && prevPlayer != null) {
      pagePlayer = prevPlayer;
    }

    final hasTexture = pagePlayer != null && pagePlayer.textureId != null;

    final overlay = isActive
        ? PlayerControlsOverlay(
            player: null,
            playerInitialized: _playerInitialized,
            isLandscapeFullScreen: _systemUi.isLandscapeFullScreen,
            showLandscapeUI: _systemUi.showLandscapeUI,
            isVideoFilled: _landscapeFill,
            onToggleVideoFit: _onToggleVideoFit,
            isPageTransitioning: false,
            isOfflinePlayback: isOfflinePlayback,
            isTheaterResource: _drama.isTheaterResource,
            danmakuEnabled: _danmakuController.enabled,
            isSpeedUp: _isSpeedUp,
            userPaused: _userPaused,
            currentEpisodeIndex: _currentEpisodeIndex,
            playbackSpeed: _playbackSpeed,
            positionMsNotifier: positionMsNotifier,
            playingNotifier: playingNotifier,
            speedButtonKey: speedButtonKey,
            seekingPositionMs: _seekingPositionMs,
            durationMsNotifier: durationMsNotifier,
            videoWidth: _player?.videoWidth ?? 0,
            videoHeight: _player?.videoHeight ?? 0,
            onBack: _onBack,
            onToggleDanmaku: _onToggleDanmaku,
            onSpeedTap: _onSpeedTap,
            onSpeedChanged: _onSpeedChanged,
            onEpisodeTap: _onEpisodeTap,
            episodeNumber: _episodes[index].index,
            dramaName: _drama.name,
            totalEpisodes: _episodes.length,
            dramaTags: _drama.tags,
            dramaIntro: _drama.intro,
            onNextEpisode: _currentEpisodeIndex < _episodes.length - 1
                ? () => _stepEpisode(1)
                : null,
            canDownload: widget.downloadService != null &&
                !isOfflinePlayback &&
                _drama.isTheaterResource &&
                _episodes.isNotEmpty,
            sleepTimerActive: _sleepTimer.isActive,
            currentQuality: isOfflinePlayback
                ? ''
                : _preloadManager
                    .selectedDefinition(_episodes[index].url.trim()),
            loadQualities: isOfflinePlayback
                ? null
                : () => _preloadManager
                    .availableDefinitions(_episodes[index].url.trim()),
            onQualityChanged: _onQualityChanged,
            onSleepDurationChanged: _onSleepDurationChanged,
            sleepTimerMinutes: _sleepTimer.isActive ? _sleepTimerMinutes : null,
            onMenuAction: _onMenuAction,
            onMenuOpened: () => _systemUi.setMenuOpen(true),
            onMenuClosed: () => _systemUi.setMenuOpen(false),
            onBottomPanelHeight: _onBottomPanelHeight,
            onTogglePlay: _onTogglePlay,
            onToggleLandscapeFullScreen: _onToggleLandscapeFullScreen,
            onSeekStart: _onSeekStart,
            onSeekChanged: _onSeekChanged,
            onSeekEnd: _onSeekEnd,
          )
        : null;

    final textureId = pagePlayer?.textureId;
    final videoWidget = textureId == null
        ? const SizedBox.shrink()
        : PlayerVideoSurface(
            textureId: textureId,
            videoWidth: pagePlayer!.videoWidth,
            videoHeight: pagePlayer.videoHeight,
            isLandscapeFullScreen: _systemUi.isLandscapeFullScreen,
            fillScreen: _landscapeFill,
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        if (hasTexture)
          isActive ? _shrinkable(videoWidget, pagePlayer) : videoWidget,
        if (isActive && hasTexture)
          _hideWhileShrunk(ListenableBuilder(
            listenable: Listenable.merge([_danmakuController, playingNotifier]),
            builder: (context, _) => DanmakuLayer(
              key: ValueKey('danmaku-${_episodes[index].url}'),
              seekGeneration: _danmakuSeekGeneration,
              comments: _danmakuController.comments,
              getPositionMs: () => positionMsNotifier.value,
              isPlaying: playingNotifier.value,
              visible: _danmakuController.enabled,
              playbackSpeed: _isSpeedUp ? 2.0 : _playbackSpeed,
              topOffset: MediaQuery.viewPaddingOf(context).top +
                  (MediaQuery.orientationOf(context) == Orientation.landscape
                      ? 8
                      : 64),
            ),
          )),
        if (isActive && _loading)
          const Center(
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 2,
            ),
          ),
        if (isActive && _errorMessage != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTapVideo,
            // 竖屏不挂双击：否则单击要等双击判定（约 300ms）才响应
            onDoubleTap:
                _systemUi.isLandscapeFullScreen ? _onDoubleTapVideo : null,
            onLongPressStart: _onLongPressStart,
            onLongPressEnd: _onLongPressEnd,
            child: Container(color: Colors.transparent),
          ),
        ),
        // 电视 / 桌面：叠加层按钮不参与焦点，遥控器按键统一由播放页处理
        // （否则焦点落到倍速/更多按钮上，OK 会直接点它们）。鼠标点击不受影响。
        if (isActive && overlay != null)
          _hideWhileShrunk(DeviceProfile.usesFocusUi
              ? ExcludeFocus(child: overlay)
              : overlay),
      ],
    );
  }

  /// 屏幕底边是系统“上滑回桌面 / 呼出导航栏”的手势区。从这里起手的上滑
  /// 交给系统，不让播放页的 PageView 接住（否则回桌面时会误翻到下一集）。
  /// 只吞竖向拖动，点击照常落到下面的选集栏。
  Widget _buildBottomEdgeGuard() {
    final media = MediaQuery.of(context);
    final zone = [
          media.systemGestureInsets.bottom,
          media.viewPadding.bottom,
          32.0,
        ].reduce((a, b) => a > b ? a : b) +
        8;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: zone,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) {},
        onVerticalDragUpdate: (_) {},
        onVerticalDragEnd: (_) {},
      ),
    );
  }

  Widget _buildLoading() {
    return PlayerWorkflowProgress(
      steps: _steps,
      loadingStatusText: _loadingStatusText,
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _errorMessage ?? '未知错误',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }

  Widget _buildNextLoading() {
    return const Positioned(
      bottom: 80,
      left: 0,
      right: 0,
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            color: Colors.white54,
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }

  Widget _buildSwipeBlockedHint() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(context).padding.bottom + 120,
      child: IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 200),
            builder: (context, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '下一集加载中',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockForwardScrollPhysics extends ScrollPhysics {
  const _BlockForwardScrollPhysics({super.parent});

  @override
  _BlockForwardScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _BlockForwardScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    // 阻止向前滑（向下滚动 = value > position.pixels）
    if (value > position.pixels &&
        position.pixels >= position.maxScrollExtent - 1) {
      return value - position.pixels;
    }
    return super.applyBoundaryConditions(position, value);
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    // 向前滑时不产生惯性
    if (velocity > 0 && position.pixels >= position.maxScrollExtent - 1) {
      return null;
    }
    return super.createBallisticSimulation(position, velocity);
  }
}
