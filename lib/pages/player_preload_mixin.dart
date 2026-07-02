import 'dart:async';

import 'package:flutter/material.dart';

import '../models/episode.dart';
import '../services/crypto_native_channel.dart';
import '../services/native_player.dart';
import '../services/theater_video_preload_manager.dart';
import 'player_page.dart';

mixin PlayerPreloadMixin on State<PlayerPage> {
  // ─── 3-Player 窗口 ─────────────────────────────────────────────────────

  NativePlayer? nextPlayer;
  int? nextEpisodeIndex;
  bool nextPlayerReady = false;

  NativePlayer? prevPlayer;
  int? prevEpisodeIndex;
  int? prevPositionMs;

  int _prepareId = 0;
  final List<NativePlayer> _disposeQueue = [];
  bool _draining = false;

  // ─── 宿主须提供 ────────────────────────────────────────────────────────

  List<Episode> get episodes;
  TheaterVideoPreloadManager get preloadManager;
  bool get isOfflinePlayback;

  // ─── 销毁队列 ──────────────────────────────────────────────────────────

  void enqueueDispose(NativePlayer player) {
    _disposeQueue.add(player);
    _drainDisposeQueue();
  }

  Future<void> _drainDisposeQueue() async {
    if (_draining) return;
    _draining = true;
    while (_disposeQueue.isNotEmpty) {
      final p = _disposeQueue.removeAt(0);
      // 先暂停再销毁，确保音频立即停止
      await p.pause();
      await p.dispose();
    }
    _draining = false;
  }

  // ─── prepareNextPlayer ─────────────────────────────────────────────────

  Future<void> prepareNextPlayer(int index) async {
    if (index < 0 || index >= episodes.length) return;
    if (nextEpisodeIndex == index && nextPlayerReady) return;

    final prepareId = ++_prepareId;

    if (nextPlayer != null && !nextPlayerReady) {
      enqueueDispose(nextPlayer!);
      nextPlayer = null;
      nextEpisodeIndex = null;
    }

    final episode = episodes[index];
    final videoId = episode.url.trim();
    if (videoId.isEmpty) return;

    String cdnUrl;
    String keyHex;

    if (isOfflinePlayback) {
      cdnUrl = videoId;
      keyHex = '';
    } else {
      try {
        final url = await preloadManager.resolvePlayUrl(videoId, episodeIndex: index);
        if (!mounted || prepareId != _prepareId) return;

        if (!url.startsWith('crypto://')) return;

        final encoded = url.substring('crypto://'.length);
        final qIdx = encoded.indexOf('?key=');
        if (qIdx < 0) return;
        cdnUrl = Uri.decodeComponent(encoded.substring(0, qIdx));
        keyHex = encoded.substring(qIdx + 5);
      } catch (e) {
        debugPrint('[Player] prepareNext resolve 失败: $e');
        return;
      }
    }

    if (!mounted || prepareId != _prepareId) return;

    // 建真实播放器前先 prewarm：把 moov + mdat 种子拉进 native 缓存。
    // 否则 create 是冷启动，要现拉整个 moov(~300KB)+box scan，叠加当前集正在
    // 播放抢带宽/解码器，首帧极易 10s 超时。prewarm 后 create 命中缓存跳过扫描，
    // 首帧时间降到“仅解码”量级。失败也无妨——create 会自行冷启动兜底。
    if (keyHex.isNotEmpty) {
      try {
        await CryptoNativeChannel.instance.prewarm(cdnUrl, keyHex);
      } catch (e) {
        debugPrint('[Player] prepareNext prewarm 失败(忽略，create 兜底): $e');
      }
      if (!mounted || prepareId != _prepareId) return;
    }

    final player = NativePlayer();
    try {
      await player.create(cdnUrl, keyHex);
    } catch (e) {
      debugPrint('[Player] prepareNext create 失败: $e');
      await player.dispose();
      return;
    }

    if (!mounted || prepareId != _prepareId) {
      await player.dispose();
      return;
    }

    // 静音 play，让 AVPlayer 开始缓冲解码，等首帧渲染出来后 pause
    unawaited(player.setVolume(0));
    unawaited(player.play());

    try {
      if (!player.firstFrameRendered) {
        await player.firstFrameStream
            .firstWhere((v) => v)
            .timeout(const Duration(seconds: 10));
      }
    } on TimeoutException {
      debugPrint('[Player] prepareNext 超时');
      unawaited(player.dispose());
      return;
    }

    if (!mounted || prepareId != _prepareId) {
      await player.dispose();
      return;
    }

    unawaited(player.pause());

    nextPlayer = player;
    nextEpisodeIndex = index;
    nextPlayerReady = true;
    if (mounted) setState(() {});
    debugPrint('[Player] prepareNext 第${index + 1}集 完成');
  }

  // ─── 预加载调度 ────────────────────────────────────────────────────────

  void schedulePreloads(int currentIndex) {
    prepareNextPlayer(currentIndex + 1);
    _preloadData(currentIndex, currentIndex + 2);
  }

  void _preloadData(int current, int target) {
    if (target < 0 || target >= episodes.length) return;
    preloadManager.preloadEpisode(
      episodes: episodes,
      currentIndex: current,
      targetIndex: target,
      isStillCurrent: () => mounted,
    );
  }

  void preloadHeaderOnly(int current, int target) {
    if (target < 0 || target >= episodes.length) return;
    preloadManager.preloadEpisodeHeaderOnly(
      episodes: episodes,
      currentIndex: current,
      targetIndex: target,
      isStillCurrent: () => mounted,
    );
  }

  // ─── 窗口清理 ──────────────────────────────────────────────────────────

  void dispose3PWindow() {
    if (prevPlayer != null) enqueueDispose(prevPlayer!);
    if (nextPlayer != null) enqueueDispose(nextPlayer!);
    prevPlayer = null;
    prevEpisodeIndex = null;
    prevPositionMs = null;
    nextPlayer = null;
    nextEpisodeIndex = null;
    nextPlayerReady = false;
  }
}