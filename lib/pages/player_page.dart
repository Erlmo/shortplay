import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../models/drama_season.dart';
import '../models/episode.dart';
import '../models/playback_record.dart';
import '../models/workflow_step.dart';
import '../services/api_client.dart';
import '../services/app_route_observer.dart';
import '../services/crypto_native_channel.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../services/native_player.dart';
import '../services/offline_playback_cache.dart';
import '../services/playback_history_store.dart';
import '../services/player_danmaku_controller.dart';
import '../services/player_sleep_timer.dart';
import '../services/player_system_ui_controller.dart';
import '../services/theater_video_preload_manager.dart';
import '../widgets/app_notice.dart';
import '../widgets/danmaku_layer.dart';
import '../widgets/player/episode_sheet.dart';
import '../widgets/player/hg_episode_panel.dart';
import '../widgets/player/player_controls_overlay.dart';
import '../widgets/player/player_loading.dart';
import '../widgets/player/player_more_menu.dart';
import '../widgets/player/player_page_overlays.dart';
import '../widgets/player/player_video_surface.dart';
import 'player_preload_mixin.dart';

// 播放页按职责拆成多个 part 文件，共享 _PlayerPageState 的私有状态：
part 'player_page/playback.dart'; // 拉目录、打开剧集、播放器订阅、自动下一集、历史
part 'player_page/seasons.dart'; // 跨季连播与切季
part 'player_page/controls.dart'; // 播放控制、菜单、选集、翻页回调
part 'player_page/keyboard.dart'; // 遥控器 / 键盘
part 'player_page/view.dart'; // 剧集页 UI 构建

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
    this.seasons,
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

  /// 详情页已加载的季列表；为空时播放页自己在后台请求。
  final DramaSeasons? seasons;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with
        PlayerPreloadMixin,
        WidgetsBindingObserver,
        RouteAware,
        SingleTickerProviderStateMixin {
  // ─── 剧 / 季 ───────────────────────────────────────────────────────────

  Drama? _selectedSeasonDrama;
  Drama get _drama => _selectedSeasonDrama ?? widget.drama;

  /// 同一部剧的全部季，用来在本季最后一集之后接着播下一季。
  DramaSeasons? _seasons;
  bool _seasonAdvancing = false;

  /// 播到本季最后一集时提前拉好的下一季目录，切季时直接复用。
  int? _nextSeasonPrefetchId;
  Future<TheaterEpisodesResult>? _nextSeasonEpisodes;
  String? _nextSeasonFirstVideoId;

  // ─── 播放器与剧集 ──────────────────────────────────────────────────────

  NativePlayer? _player;
  NativePlayer? _preparingPlayer;
  List<Episode> _episodes = const [];
  int _currentEpisodeIndex = 0;
  bool _playerInitialized = false;
  int _requestId = 0;
  int _catalogRequestId = 0;
  bool _didPreloadN2 = false;
  bool _didPreloadN3 = false;
  int _lastHistorySaveMs = 0;

  StreamSubscription<String>? _errorSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Duration>? _durationSub;

  final positionMsNotifier = ValueNotifier<int>(0);
  final playingNotifier = ValueNotifier<bool>(false);
  final durationMsNotifier = ValueNotifier<int>(0);
  final speedButtonKey = GlobalKey();

  // ─── 加载 / 错误 ───────────────────────────────────────────────────────

  bool _loading = true;
  String? _errorMessage;
  bool _showNextLoading = false;
  final String _loadingStatusText = '正在准备播放资源';
  List<WorkflowStep> _steps = const [
    WorkflowStep(id: 'episodes', label: '获取剧集列表', status: StepStatus.running),
    WorkflowStep(id: 'resolve', label: '解析播放地址'),
    WorkflowStep(id: 'player', label: '初始化播放器'),
  ];

  // ─── 翻页 ──────────────────────────────────────────────────────────────

  PageController? _pageController;
  bool _programmaticJump = false;
  bool _swipeBlocked = false;
  Timer? _swipeBlockTimer;

  // ─── 播放状态 ──────────────────────────────────────────────────────────

  bool _userPaused = false;
  bool _pausedByLifecycle = false;
  // 本页被新路由（如再次打开的播放页）覆盖时暂停，新路由弹出回到本页时恢复，
  // 与 _pausedByLifecycle 分开记，避免两套恢复逻辑互相误触发。
  bool _pausedByRoute = false;
  bool _sleepStopped = false;
  int _sleepPositionMs = 0;
  int? _sleepTimerMinutes;
  bool _isSpeedUp = false;
  int _activePointers = 0;
  double _playbackSpeed = 1.0;
  double? _seekingPositionMs;
  bool _resumeAfterSeek = false;
  bool _landscapeFill = false;

  // ─── 菜单 / 面板 ───────────────────────────────────────────────────────

  bool _actionSheetOpen = false;
  bool _moreMenuOpen = false;

  // 红果：竖屏打开选集面板时，画面缩到面板上方（0 = 全屏，1 = 缩小）
  late final AnimationController _episodeShrink;

  /// 当前缩放目标对应的底部面板高度（选集面板 = 屏高 50%，“…”面板按实测高度）
  double? _shrinkPanelHeight;

  // ─── 遥控器 / 键盘 ─────────────────────────────────────────────────────

  final FocusNode _keyFocus = FocusNode(debugLabel: 'player-keys');
  bool _showKeyHint = false;
  Timer? _keyHintTimer;
  // 长按 OK 呼出菜单：按下时起计时，松开前到点就打开菜单，否则当作单击暂停
  Timer? _okHoldTimer;

  // ─── 协作对象 ──────────────────────────────────────────────────────────

  late final PlayerSystemUiController _systemUi;
  late final PlayerSleepTimer _sleepTimer;
  late final PlayerDanmakuController _danmakuController;
  int _danmakuSeekGeneration = 0;
  late final TheaterVideoPreloadManager _preloadManager;

  // ─── PlayerPreloadMixin ────────────────────────────────────────────────

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
    _seasons = widget.seasons;
    if (_seasons == null) unawaited(_loadSeasons());
    unawaited(_systemUi.setFullScreen());
    NativePlayer.setKeepScreenOn(true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _flashKeyHint());
    _prepare();
  }

  void _onSystemUiChanged() {
    if (mounted) setState(() {});
  }

  /// 供 part 文件里的 extension 刷新界面（setState 是 protected，extension 不能直接调）。
  void _refresh([VoidCallback? fn]) => setState(fn ?? () {});

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
    // 退出播放页：记下当前集和进度（定时停止时已经保存过）。
    if (_playerInitialized && !_sleepStopped) _saveHistory();
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
    _cancelPlayerSubscriptions();
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
      // 切到后台可能被系统回收，先把进度存下来。
      if (_playerInitialized && !_sleepStopped) _saveHistory();
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
                  const PlayerBottomEdgeGuard(),
                if (_loading)
                  PlayerWorkflowProgress(
                    steps: _steps,
                    loadingStatusText: _loadingStatusText,
                  ),
                if (!_loading && _errorMessage != null)
                  PlayerErrorView(message: _errorMessage),
                if (_swipeBlocked) const PlayerSwipeBlockedHint(),
                if (_showNextLoading) const PlayerNextLoading(),
                if (_showKeyHint) const PlayerKeyHint(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
