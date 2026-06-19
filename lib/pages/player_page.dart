import 'dart:async';

import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../models/episode.dart';
import '../models/workflow_step.dart';
import '../services/api_client.dart';
import '../models/playback_record.dart';
import '../services/app_route_observer.dart';
import '../services/download_service.dart';
import '../services/crypto_native_channel.dart';
import '../services/native_player.dart';
import '../services/playback_history_store.dart';
import '../services/player_danmaku_controller.dart';
import '../services/player_system_ui_controller.dart';
import '../services/theater_video_preload_manager.dart';
import '../widgets/player/episode_sheet.dart';
import '../widgets/player/player_controls_overlay.dart';
import '../widgets/player/player_loading.dart';
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
    with PlayerPreloadMixin, WidgetsBindingObserver, RouteAware {
  NativePlayer? _player;
  bool _playerInitialized = false;
  int _currentEpisodeIndex = 0;
  int _requestId = 0;

  bool _programmaticJump = false;
  bool _loading = true;
  String? _errorMessage;
  bool _showNextLoading = false;
  bool _swipeBlocked = false;
  Timer? _swipeBlockTimer;
  bool _userPaused = false;
  bool _pausedByLifecycle = false;
  // 本页被新路由（如再次打开的播放页）覆盖时暂停，新路由弹出回到本页时恢复，
  // 与 _pausedByLifecycle 分开记，避免两套恢复逻辑互相误触发。
  bool _pausedByRoute = false;
  bool _isSpeedUp = false;
  int _activePointers = 0;
  double _playbackSpeed = 1.0;
  double? _seekingPositionMs;
  String _loadingStatusText = '正在准备播放资源';
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
  late final PlayerDanmakuController _danmakuController;
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
    WidgetsBinding.instance.addObserver(this);
    _systemUi = PlayerSystemUiController();
    _systemUi.addListener(_onSystemUiChanged);
    _preloadManager = widget.preloadManager ??
        TheaterVideoPreloadManager(apiClient: widget.apiClient);
    _danmakuController = PlayerDanmakuController(apiClient: widget.apiClient);
    _currentEpisodeIndex = widget.initialEpisodeIndex ?? 0;
    unawaited(_systemUi.setFullScreen());
    NativePlayer.setKeepScreenOn(true);
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
    if (_pausedByRoute) {
      _pausedByRoute = false;
      // 用户未手动暂停、也不是被生命周期暂停时才自动续播。
      if (!_userPaused && !_pausedByLifecycle) _player?.play();
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    NativePlayer.setKeepScreenOn(false);
    _swipeBlockTimer?.cancel();
    _systemUi.removeListener(_onSystemUiChanged);
    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
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
      if (_pausedByLifecycle) {
        _pausedByLifecycle = false;
        _player?.play();
      }
    }
  }

  // ─── 数据加载 ──────────────────────────────────────────────────────────

  Future<void> _prepare() async {
    _steps = [
      const WorkflowStep(id: 'episodes', label: '获取剧集列表', status: StepStatus.running),
      const WorkflowStep(id: 'resolve', label: '解析播放地址'),
      const WorkflowStep(id: 'player', label: '初始化播放器'),
    ];
    setState(() {});

    try {
      if (widget.offlineEpisodes != null) {
        _episodes = widget.offlineEpisodes!;
      } else if (widget.prefetchedEpisodes != null) {
        final result = await widget.prefetchedEpisodes!;
        if (!mounted) return;
        _episodes = _chaptersToEpisodes(result.chapters);
      } else {
        final result = await widget.apiClient
            .fetchTheaterEpisodes(widget.drama.id.toString());
        if (!mounted) return;
        _episodes = _chaptersToEpisodes(result.chapters);
      }

      _updateStep('episodes', StepStatus.success);
      _updateStep('resolve', StepStatus.running);

      if (_episodes.isEmpty) {
        setState(() {
          _loading = false;
          _errorMessage = '暂无可播放的剧集';
        });
        return;
      }
      if (widget.initialEpisodeNumber != null) {
        final idx = widget.initialEpisodeNumber! - 1;
        if (idx >= 0 && idx < _episodes.length) _currentEpisodeIndex = idx;
      }
      _currentEpisodeIndex =
          _currentEpisodeIndex.clamp(0, _episodes.length - 1);
      _pageController = PageController(initialPage: _currentEpisodeIndex);
      await _openEpisode(
        _currentEpisodeIndex,
        initialSeekMs: widget.initialPositionMs,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '加载失败: $e';
      });
    }
  }

  void _updateStep(String id, StepStatus status) {
    _steps = _steps.map((s) => s.id == id ? s.copyWith(status: status) : s).toList();
    if (mounted) setState(() {});
  }

  List<Episode> _chaptersToEpisodes(List<TheaterChapter> chapters) {
    return chapters
        .asMap()
        .entries
        .map((e) => Episode(
              // e.key 是 0-based 下标；index 字段语义为 1-based 集号
              //（选集面板/离线页直接显示，下载文件名也用它），故 +1。
              index: e.key + 1,
              name: e.value.title,
              size: 0,
              url: e.value.itemId,
            ))
        .toList();
  }

  // ─── 打开剧集 ──────────────────────────────────────────────────────────

  Future<void> _openEpisode(int index, {int? initialSeekMs}) async {
    if (index < 0 || index >= _episodes.length) return;
    final reqId = ++_requestId;

    final direction = index - _currentEpisodeIndex;
    _currentEpisodeIndex = index;
    _didPreloadN2 = false;
    _didPreloadN3 = false;

    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    NativePlayer? reusedPlayer;

    if (direction > 0 && nextPlayer != null && nextEpisodeIndex == index) {
      if (_player != null) {
        unawaited(_player!.pause());
        unawaited(_player!.setVolume(0));
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
      unawaited(reusedPlayer.setVolume(1.0));
      unawaited(reusedPlayer.setRate(_isSpeedUp ? 2.0 : _playbackSpeed));
      unawaited(reusedPlayer.play());
      if (initialSeekMs != null && initialSeekMs > 0) {
        unawaited(reusedPlayer.seek(Duration(milliseconds: initialSeekMs)));
      }
      _setupSubscriptions(reusedPlayer, reqId);
      _danmakuController.clearComments();
      _loadDanmaku();
      schedulePreloads(_currentEpisodeIndex);
      _saveHistory();
      return;
    }

    // 新建播放器路径
    _steps = [
      const WorkflowStep(id: 'episodes', label: '获取剧集列表', status: StepStatus.success),
      const WorkflowStep(id: 'resolve', label: '解析播放地址', status: StepStatus.running),
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
        cdnUrl = videoId;
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
        _errorMessage = '解析播放地址失败: $e';
      });
      return;
    }

    if (keyHex.isNotEmpty) {
      await CryptoNativeChannel.instance.prewarm(cdnUrl, keyHex);
      if (!mounted || reqId != _requestId) return;
    }

    if (keyHex.isNotEmpty) {
      await CryptoNativeChannel.instance.prewarm(cdnUrl, keyHex);
      if (!mounted || reqId != _requestId) return;
    }

    final player = NativePlayer();
    try {
      await player.create(cdnUrl, keyHex);
    } catch (e) {
      if (!mounted || reqId != _requestId) {
        unawaited(player.dispose());
        return;
      }
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
      if (!player.firstFrameRendered) {
        await player.firstFrameStream
            .firstWhere((v) => v)
            .timeout(const Duration(seconds: 15));
      }
    } on TimeoutException {
      if (!mounted || reqId != _requestId) {
        unawaited(player.dispose());
        return;
      }
      setState(() {
        _loading = false;
        _errorMessage = '加载超时，请重试';
      });
      unawaited(player.dispose());
      return;
    }

    if (!mounted || reqId != _requestId) {
      unawaited(player.dispose());
      return;
    }

    _player = player;
    _playerInitialized = true;
    _loading = false;
    _showNextLoading = false;
    positionMsNotifier.value = player.position.inMilliseconds;
    durationMsNotifier.value = player.duration.inMilliseconds;
    playingNotifier.value = true;
    setState(() {});

    _setupSubscriptions(player, reqId);
    _danmakuController.clearComments();
    _loadDanmaku();
    schedulePreloads(_currentEpisodeIndex);
    _saveHistory();
  }

  // ─── 订阅 ──────────────────────────────────────────────────────────────

  void _setupSubscriptions(NativePlayer player, int reqId) {
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
      isTheaterResource: widget.drama.isTheaterResource,
      isOfflinePlayback: isOfflinePlayback,
    ));
  }

  // ─── 自动下一集 ────────────────────────────────────────────────────────

  void _onAutoNext() {
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
    final drama = widget.drama;
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
    _seekingPositionMs = ms;
  }

  void _onSeekChanged(double ms) {
    _seekingPositionMs = ms;
  }

  void _onSeekEnd(double ms) {
    final player = _player;
    if (player != null && _playerInitialized) {
      player.seek(Duration(milliseconds: ms.toInt()));
      if (_resumeAfterSeek) {
        player.play();
      }
    }
    _seekingPositionMs = null;
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
      currentEpisode: _episodes.isNotEmpty ? _episodes[_currentEpisodeIndex] : null,
      durationMs: durationMsNotifier.value,
    ));
    setState(() {});
  }

  void _loadDanmaku() {
    if (isOfflinePlayback || !widget.drama.isTheaterResource) return;
    if (!_danmakuController.enabled) return;
    if (_currentEpisodeIndex >= _episodes.length) return;
    unawaited(_danmakuController.loadForEpisode(
      episode: _episodes[_currentEpisodeIndex],
      durationMs: durationMsNotifier.value,
      isOfflinePlayback: isOfflinePlayback,
    ));
  }

  void _onEpisodeTap() {
    final episodeNotifier = ValueNotifier<int>(_currentEpisodeIndex);
    showPlayerEpisodeSheet(
      context: context,
      isLandscapeFullScreen: _systemUi.isLandscapeFullScreen,
      dramaName: widget.drama.name,
      episodes: _episodes,
      episodeNotifier: episodeNotifier,
      onSelectEpisode: (idx) {
        if (idx == _currentEpisodeIndex) return;
        _programmaticJump = true;
        _pageController?.jumpToPage(idx);
        _programmaticJump = false;
        unawaited(_openEpisode(idx));
      },
    );
  }

  void _onToggleLandscapeFullScreen() {
    _systemUi.toggleLandscapeFullScreen();
    setState(() {});
  }

  void _onBack() {
    if (_systemUi.isLandscapeFullScreen) {
      _onToggleLandscapeFullScreen();
      return;
    }
    Navigator.of(context).pop();
  }

  void _onTapVideo() {
    if (_systemUi.isLandscapeFullScreen) {
      _systemUi.showUIAndResetTimer();
      setState(() {});
    }
  }

  void _onDoubleTapVideo() {
    _onTogglePlay();
  }

  void _onPageChanged(int index) {
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

    // 正常翻页
    _swipeBlockTimer?.cancel();
    setState(() => _swipeBlocked = false);
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
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
            if (_loading) _buildLoading(),
            if (!_loading && _errorMessage != null) _buildError(),
            if (_swipeBlocked) _buildSwipeBlockedHint(),
            if (_showNextLoading) _buildNextLoading(),
          ],
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
        controller: _pageController,
        scrollDirection: Axis.vertical,
        physics: blockForward
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

  Widget _buildEpisodePage(int index) {
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
            isPageTransitioning: false,
            isOfflinePlayback: isOfflinePlayback,
            isTheaterResource: widget.drama.isTheaterResource,
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
            onEpisodeTap: _onEpisodeTap,
            onTogglePlay: _onTogglePlay,
            onToggleLandscapeFullScreen: _onToggleLandscapeFullScreen,
            onSeekStart: _onSeekStart,
            onSeekChanged: _onSeekChanged,
            onSeekEnd: _onSeekEnd,
          )
        : null;

    Widget videoWidget = const SizedBox.shrink();
    if (hasTexture) {
      final vw = pagePlayer!.videoWidth > 0 ? pagePlayer.videoWidth.toDouble() : 9.0;
      final vh = pagePlayer.videoHeight > 0 ? pagePlayer.videoHeight.toDouble() : 16.0;
      final aspectRatio = vw / vh;

      if (aspectRatio > 1.0 && !_systemUi.isLandscapeFullScreen) {
        videoWidget = Container(
          color: Colors.black,
          child: Center(
            child: AspectRatio(
              aspectRatio: aspectRatio,
              child: Texture(textureId: pagePlayer!.textureId!),
            ),
          ),
        );
      } else {
        videoWidget = SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            alignment: const Alignment(0, 0.45),
            child: SizedBox(
              width: vw,
              height: vh,
              child: Texture(textureId: pagePlayer!.textureId!),
            ),
          ),
        );
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        if (hasTexture) videoWidget,
        if (isActive && hasTexture)
          ListenableBuilder(
            listenable: Listenable.merge([_danmakuController, playingNotifier]),
            builder: (context, _) => DanmakuLayer(
              comments: _danmakuController.comments,
              getPositionMs: () => positionMsNotifier.value,
              isPlaying: playingNotifier.value,
              visible: _danmakuController.enabled,
              playbackSpeed: _isSpeedUp ? 2.0 : _playbackSpeed,
              topOffset: MediaQuery.of(context).viewPadding.top + 64,
            ),
          ),
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
            onDoubleTap: _onDoubleTapVideo,
            onLongPressStart: _onLongPressStart,
            onLongPressEnd: _onLongPressEnd,
            child: Container(color: Colors.transparent),
          ),
        ),
        if (isActive && overlay != null) overlay,
      ],
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
    if (value > position.pixels && position.pixels >= position.maxScrollExtent - 1) {
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
