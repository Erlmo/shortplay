import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

import '../models/episode.dart';
import '../services/crypto_native_channel.dart';
import '../services/native_player.dart';
import '../services/offline_playback_cache.dart';
import '../services/theater_video_preload_manager.dart';
import 'player_page.dart';

/// 预渲染与预下载的参数，参考红果短剧（7.3.9）内置的默认配置。
class PlaybackPreparePolicy {
  const PlaybackPreparePolicy({
    this.firstFrameGrace = const Duration(milliseconds: 300),
    this.preloadCount = 3,
    this.preloadBytesWifi = 3 * 1024 * 1024,
    this.preloadBytesCellular = 1024 * 1024,
    this.standbyBytes = 500 * 1024,
    this.retryDelay = const Duration(seconds: 5),
    this.maxFailures = 3,
  });

  /// 当前集出首帧后（或起播超过这个时间仍未出首帧）才开始预渲染，保证当前集先起播。
  final Duration firstFrameGrace;

  /// 沿滑动方向往后预下载几集（含预渲染的那一集）。
  final int preloadCount;

  /// 每集预下载的开头字节数：Wi-Fi 多下，移动网络少下。
  final int preloadBytesWifi;
  final int preloadBytesCellular;

  /// 预渲染那一集只下够解出首帧的数据。
  final int standbyBytes;

  /// 失败后至少隔这么久才重试，避免网络抖动时一下子用完重试次数。
  final Duration retryDelay;

  /// 同一项预加载最多失败几次，之后本集不再重试。
  final int maxFailures;
}

/// 播放页的播放器调度：只有「当前播放器」和一个「预渲染播放器」。
///
/// - 预渲染播放器按最近一次滑动方向准备相邻一集（往下滑准备下一集，往回滑准备上一集），
///   静音解出首帧后暂停待命，画面直接显示在相邻页上，滑过去时直接接管播放。
/// - 切集时旧播放器先停声，再延迟释放；不再保留上一集的播放器。
/// - 预渲染完成后，沿滑动方向串行预下载后面几集的开头；当前集卡顿时全部暂停，把带宽让给正在看的。
mixin PlayerPreloadMixin on State<PlayerPage> {
  PlaybackPreparePolicy get preparePolicy => const PlaybackPreparePolicy();

  // ─── 预渲染播放器 ──────────────────────────────────────────────────────

  NativePlayer? standbyPlayer;
  int? standbyIndex;
  bool standbyReady = false;
  PlaybackEngineKey? _standbyKey;

  /// 最近一次切集的方向：1 = 往下（下一集），-1 = 往回（上一集）。
  int swipeDirection = 1;

  PlaybackCancellation? playbackActivation;

  PlaybackEngineKey engineKey(int index) => PlaybackEngineKey(
        episodes[index].url.trim(),
        revision: preloadManager.sourceRevision,
        variant: preloadManager.preferredDefinition,
        localPath: cachedEpisodePath(index),
      );

  // ─── 宿主须提供 ────────────────────────────────────────────────────────

  List<Episode> get episodes;
  TheaterVideoPreloadManager get preloadManager;
  bool get isOfflinePlayback;
  String? cachedEpisodePath(int index);

  /// 当前播放器的状态，由宿主提供：是否已出首帧、是否卡顿中。
  NativePlayer? get currentPlayer;
  int get currentEpisodeIndex;

  // ─── 调度状态 ──────────────────────────────────────────────────────────

  int _epoch = 0;
  bool _running = false;
  bool _pendingWake = false;
  bool _closed = false;
  PlaybackCancellation? _job;
  bool _jobUsesNetwork = false;
  Timer? _graceTimer;
  DateTime? _episodeStartedAt;
  final Set<String> _done = {};
  final Map<String, int> _failures = {};
  final Map<String, DateTime> _lastFailure = {};
  final Map<String, Future<bool> Function(PlaybackCancellation)> _background =
      {};
  bool _wifi = true;

  /// 新的一集开始播放：重置本集的预加载进度，并安排预渲染。
  void startPreparation(int index) {
    if (_closed) return;
    releaseParkedUnlessAdjacent(index);
    _cancelJob();
    ++_epoch;
    _done.clear();
    _failures.clear();
    _lastFailure.clear();
    _episodeStartedAt = DateTime.now();
    unawaited(_refreshNetworkType());
    _graceTimer?.cancel();
    _graceTimer = Timer(preparePolicy.firstFrameGrace, schedulePreparation);
    schedulePreparation();
  }

  /// 取消所有后台准备（不释放已就绪的预渲染播放器）。切集、离开页面、切到后台时调用。
  void cancelPlaybackPreparation() {
    playbackActivation?.cancel();
    _graceTimer?.cancel();
    ++_epoch;
    _cancelJob();
  }

  /// 低优先级的后台网络任务（如下一季首集），同样受卡顿保护，排在预加载之后执行。
  void enqueueBackground(
      String key, Future<bool> Function(PlaybackCancellation) task) {
    if (_closed) return;
    _background.putIfAbsent('background:$key', () => task);
    schedulePreparation();
  }

  void _cancelJob() {
    _job?.cancel();
    _job = null;
    _jobUsesNetwork = false;
  }

  /// 当前集已出首帧（或起播已超过宽限时间）。
  bool get _currentStarted {
    final player = currentPlayer;
    if (player == null) return false;
    if (player.firstFrameRendered) return true;
    final started = _episodeStartedAt;
    return started != null &&
        DateTime.now().difference(started) >= preparePolicy.firstFrameGrace;
  }

  /// 当前集卡顿时不占用网络；本地文件不受影响。
  bool get _networkSafe {
    final player = currentPlayer;
    if (player == null) return false;
    if (cachedEpisodePath(currentEpisodeIndex) != null) return true;
    return !player.buffering;
  }

  /// 播放状态变化时调用：条件满足就推进准备工作，卡顿时停止占用网络的任务。
  void schedulePreparation() {
    if (_closed || episodes.isEmpty) return;
    if (!_networkSafe && _jobUsesNetwork) _cancelJob();
    if (_running) {
      _pendingWake = true;
      return;
    }
    if (!_currentStarted) return;
    _running = true;
    unawaited(_drain(_epoch));
  }

  Future<void> _drain(int epoch) async {
    try {
      final current = currentEpisodeIndex;
      final dir = swipeDirection;
      bool stale() => _closed || epoch != _epoch || !mounted;

      // 1. 预渲染：沿滑动方向的相邻一集；到头了就准备另一侧。
      var target = current + dir;
      if (target < 0 || target >= episodes.length) target = current - dir;
      if (target >= 0 &&
          target < episodes.length &&
          target != current &&
          !(parkedIndex == target && parkedPlayer != null)) {
        final ok = await _runStep('standby:$target',
            local: cachedEpisodePath(target) != null,
            evenWhileBuffering: true,
            task: (token) => prepareStandby(target, cancellation: token));
        if (stale() || ok == null) return;
      }

      // 2. 沿滑动方向预下载后面几集的开头（不建播放器）。
      for (var offset = 2; offset <= preparePolicy.preloadCount; offset++) {
        final index = current + dir * offset;
        if (index < 0 || index >= episodes.length) break;
        if (isOfflinePlayback || cachedEpisodePath(index) != null) continue;
        final ok = await _runStep('preload:$index',
            task: (token) => _preloadEpisode(index, token));
        if (stale() || ok == null) return;
      }

      // 3. 反方向的相邻一集只提前解析播放地址，往回滑时不用再等后端。
      final back = current - dir;
      if (back >= 0 &&
          back < episodes.length &&
          back != target &&
          !isOfflinePlayback &&
          cachedEpisodePath(back) == null) {
        final ok = await _runStep('resolve:$back',
            task: (token) => _resolveOnly(back, token));
        if (stale() || ok == null) return;
      }

      // 4. 其他后台任务（下一季首集等）。
      for (final key in _background.keys.toList()) {
        final task = _background[key];
        if (task == null) continue;
        final ok = await _runStep(key, task: task);
        if (stale() || ok == null) return;
        if (ok) _background.remove(key);
      }
    } finally {
      _running = false;
      _job = null;
      _jobUsesNetwork = false;
      if (_pendingWake) {
        _pendingWake = false;
        schedulePreparation();
      }
    }
  }

  /// 执行一步准备工作。返回 true/false 表示完成或失败（失败不阻塞后续步骤）；
  /// 返回 null 表示需要停下（被取消或当前集卡顿），等下一次状态变化再继续。
  Future<bool?> _runStep(String key,
      {bool local = false,
      bool evenWhileBuffering = false,
      required Future<bool> Function(PlaybackCancellation) task}) async {
    if (_done.contains(key)) return true;
    if ((_failures[key] ?? 0) >= preparePolicy.maxFailures) return false;
    final lastFailure = _lastFailure[key];
    if (lastFailure != null &&
        DateTime.now().difference(lastFailure) < preparePolicy.retryDelay) {
      return false;
    }
    // 预渲染相邻集只下够首帧的数据，和红果一样不等当前集缓冲结束；其余预下载要等当前集不卡。
    if (!local && !evenWhileBuffering && !_networkSafe) return null;
    final token = PlaybackCancellation();
    _job = token;
    _jobUsesNetwork = !local && !evenWhileBuffering;
    try {
      final ok = await task(token);
      if (token.isCancelled) return null;
      if (ok) {
        _done.add(key);
      } else {
        _failures[key] = (_failures[key] ?? 0) + 1;
        _lastFailure[key] = DateTime.now();
      }
      return ok;
    } on PlaybackCancelled {
      return null;
    } catch (error) {
      debugPrint('[Playback] 预加载失败 $key: $error');
      _failures[key] = (_failures[key] ?? 0) + 1;
      _lastFailure[key] = DateTime.now();
      return false;
    } finally {
      if (identical(_job, token)) {
        _job = null;
        _jobUsesNetwork = false;
      }
    }
  }

  /// 每集开始时读一次网络类型，决定预下载多少；读取失败按 Wi-Fi 处理。
  Future<void> _refreshNetworkType() async {
    try {
      final results = await Connectivity().checkConnectivity();
      _wifi = !results.contains(ConnectivityResult.mobile) ||
          results.contains(ConnectivityResult.wifi);
    } catch (_) {
      _wifi = true;
    }
  }

  int get _preloadBytes => _wifi
      ? preparePolicy.preloadBytesWifi
      : preparePolicy.preloadBytesCellular;

  Future<bool> _preloadEpisode(int index, PlaybackCancellation token) async {
    var ready = false;
    await preloadManager.preloadEpisode(
      episodes: episodes,
      currentIndex: index - 1,
      targetIndex: index,
      isStillCurrent: () => mounted && !token.isCancelled,
      cancellation: token,
      prefetchBytes: _preloadBytes,
      onNextEpisodeReady: () => ready = true,
    );
    token.check();
    return ready ||
        preloadManager.isMediaPrefetched(episodes[index].url.trim());
  }

  Future<bool> _resolveOnly(int index, PlaybackCancellation token) async {
    await token.wait(preloadManager.resolvePlayUrl(episodes[index].url.trim(),
        forPreload: true, episodeIndex: index, maxRetries: 1));
    return true;
  }

  // ─── 预渲染 ────────────────────────────────────────────────────────────

  /// 为第 [index] 集准备预渲染播放器：解析地址、下够首帧数据、静音解出首帧后暂停待命。
  Future<bool> prepareStandby(int index,
      {required PlaybackCancellation cancellation}) async {
    if (index < 0 || index >= episodes.length) return false;
    final key = engineKey(index);
    if (standbyIndex == index &&
        standbyReady &&
        standbyPlayer != null &&
        _standbyKey == key &&
        standbyPlayer!.isReusable) {
      return true;
    }
    discardStandby();
    void check() {
      cancellation.check();
      if (!mounted || index >= episodes.length || engineKey(index) != key) {
        throw const PlaybackCancelled();
      }
    }

    final videoId = episodes[index].url.trim();
    if (videoId.isEmpty) return false;
    NativePlayer? created;
    var published = false;
    try {
      check();
      String cdnUrl;
      var keyHex = '';
      final localPath = cachedEpisodePath(index);
      if (localPath != null) {
        cdnUrl = await cancellation
            .wait(OfflinePlaybackCache.playableFileUri(localPath));
      } else {
        final url = await cancellation.wait(preloadManager.resolvePlayUrl(
            videoId,
            forPreload: true,
            episodeIndex: index,
            maxRetries: 1));
        check();
        await preloadManager.prefetchMedia(videoId, cancellation,
            bytes: preparePolicy.standbyBytes);
        check();
        final source = CryptoNativeChannel.splitCryptoUrl(url);
        if (source == null) return false;
        cdnUrl = source.cdnUrl;
        keyHex = source.keyHex;
      }
      check();
      if (keyHex.isNotEmpty) {
        // 原生预热不能中途取消，等它结束再检查是否已过期。
        await CryptoNativeChannel.instance.prewarm(cdnUrl, keyHex);
        check();
      }
      final player = NativePlayer();
      created = player;
      // 往回预渲染已看过的集时，从记住的进度开始准备。
      final resumeMs = resumePositionOf(index);
      await cancellation.wait(player.create(cdnUrl, keyHex,
          initialPositionMs:
              resumeMs != null && resumeMs > 0 ? resumeMs : null));
      check();
      await prepareFirstFrame(
        cancellation: cancellation,
        mute: () => player.setVolume(0),
        prepare: player.prepareFirstFrame,
        waitForFrame: () =>
            player.waitForFirstFrame(timeout: const Duration(seconds: 10)),
        pause: player.pause,
        park: () => player.setActive(false),
      );
      check();
      standbyPlayer = player;
      standbyIndex = index;
      standbyReady = true;
      _standbyKey = key;
      published = true;
      if (mounted) setState(() {});
      debugPrint('[Playback] 预渲染就绪：第${index + 1}集');
      return true;
    } on PlaybackCancelled {
      rethrow;
    } catch (error) {
      debugPrint('[Playback] 预渲染失败：第${index + 1}集 $error');
      return false;
    } finally {
      if (!published && created != null) await created.dispose();
    }
  }

  /// 取走为第 [index] 集预渲染好的播放器；不匹配时返回 null。
  NativePlayer? takeStandby(int index) {
    final player = standbyPlayer;
    if (player == null ||
        standbyIndex != index ||
        !standbyReady ||
        _standbyKey != engineKey(index) ||
        !player.isReusable) {
      return null;
    }
    standbyPlayer = null;
    standbyIndex = null;
    standbyReady = false;
    _standbyKey = null;
    return player;
  }

  /// 释放预渲染播放器（切清晰度、跳集、离开页面时）。
  void discardStandby() {
    final player = standbyPlayer;
    standbyPlayer = null;
    standbyIndex = null;
    standbyReady = false;
    _standbyKey = null;
    if (player != null) enqueueDispose(player);
  }

  // ─── 停放的上一集 ──────────────────────────────────────────────────────

  /// 刚换下来的上一集播放器：暂停、静音、停止下载，保留最后一帧画面和播放进度。
  /// 往回滑时直接接管，从原位置接着播，没有加载画面。
  NativePlayer? parkedPlayer;
  int? parkedIndex;
  PlaybackEngineKey? _parkedKey;

  /// 每集最后的播放进度（毫秒）。停放的播放器释放后，再回到这一集时从这里继续。
  final Map<int, int> _resumePositions = {};

  /// 记下第 [index] 集播到的位置；接近片尾时清除，下次从头播。
  void rememberPosition(int index, NativePlayer player) {
    final position = player.position.inMilliseconds;
    final duration = player.duration.inMilliseconds;
    if (player.completed ||
        position <= 0 ||
        (duration > 0 && position >= duration - 1500)) {
      _resumePositions.remove(index);
    } else {
      _resumePositions[index] = position;
    }
  }

  /// 第 [index] 集记住的续播位置；没有则为 null。
  int? resumePositionOf(int index) => _resumePositions[index];

  /// 最近离开的几集各自停住的画面。往回滑时先显示它，后台从记住的进度重新起播，看起来像没离开过。
  final Map<int, FrameSnapshot> _snapshots = {};
  static const _maxSnapshots = 10;

  FrameSnapshot? snapshotOf(int index) => _snapshots[index];

  Future<void> _captureSnapshot(int index, NativePlayer player) async {
    final snapshot = await player.captureFrame();
    if (snapshot == null || !mounted) return;
    _snapshots.remove(index);
    _snapshots[index] = snapshot;
    while (_snapshots.length > _maxSnapshots) {
      _snapshots.remove(_snapshots.keys.first);
    }
  }

  /// 换下来的播放器：立即停声、停止下载和解码，作为「上一集」停放；原来停放的那个释放。
  void parkPlayer(NativePlayer player, int index) {
    rememberPosition(index, player);
    // 先截下停住的画面，再停声停放；截图失败不影响切集。
    unawaited(_captureSnapshot(index, player));
    if (parkedPlayer != null && !identical(parkedPlayer, player)) {
      enqueueDispose(parkedPlayer!);
    }
    unawaited(player.transition(() async {
      await player.setVolume(0);
      await player.pause();
      await player.setActive(false);
    }).catchError((Object error) {
      debugPrint('[Playback] 停放旧播放器失败: $error');
    }));
    parkedPlayer = player;
    parkedIndex = index;
    _parkedKey =
        index >= 0 && index < episodes.length ? engineKey(index) : null;
  }

  /// 取走停放在第 [index] 集的播放器；不匹配时返回 null。
  NativePlayer? takeParked(int index) {
    final player = parkedPlayer;
    if (player == null ||
        parkedIndex != index ||
        _parkedKey != engineKey(index) ||
        !player.isReusable) {
      return null;
    }
    parkedPlayer = null;
    parkedIndex = null;
    _parkedKey = null;
    return player;
  }

  /// 停放的播放器不再和当前集相邻（跳集、切清晰度后）时释放。
  void releaseParkedUnlessAdjacent(int current) {
    final index = parkedIndex;
    if (parkedPlayer == null || index == null) return;
    if ((index - current).abs() == 1 && _parkedKey == engineKey(index)) return;
    discardParked();
  }

  void discardParked() {
    final player = parkedPlayer;
    parkedPlayer = null;
    parkedIndex = null;
    _parkedKey = null;
    if (player != null) enqueueDispose(player);
  }

  // ─── 销毁队列 ──────────────────────────────────────────────────────────

  final List<NativePlayer> _disposeQueue = [];
  bool _draining = false;

  void enqueueDispose(NativePlayer player) {
    if (identical(player, parkedPlayer)) {
      parkedPlayer = null;
      parkedIndex = null;
      _parkedKey = null;
    }
    if (identical(player, standbyPlayer)) {
      standbyPlayer = null;
      standbyIndex = null;
      standbyReady = false;
      _standbyKey = null;
    }
    if (_disposeQueue.contains(player)) return;
    _disposeQueue.add(player);
    unawaited(_drainDisposeQueue());
  }

  Future<void> _drainDisposeQueue() async {
    if (_draining) return;
    _draining = true;
    while (_disposeQueue.isNotEmpty) {
      final player = _disposeQueue.removeAt(0);
      // 先暂停再销毁，确保声音立即停止。
      try {
        await player.pause();
      } catch (error) {
        debugPrint('[Player] 暂停待释放播放器失败: $error');
      } finally {
        try {
          await player.dispose();
        } catch (error) {
          debugPrint('[Player] 释放播放器失败: $error');
        }
      }
    }
    _draining = false;
  }

  /// 离开页面：取消所有准备工作并释放预渲染播放器。
  void closePreparation() {
    _closed = true;
    cancelPlaybackPreparation();
    _background.clear();
    discardStandby();
    discardParked();
  }
}
