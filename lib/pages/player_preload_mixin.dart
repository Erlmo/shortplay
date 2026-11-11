import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

import '../models/episode.dart';
import '../services/crypto_native_channel.dart';
import '../services/native_player.dart';
import '../services/offline_playback_cache.dart';
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

  late final PreparedPlaybackStore<NativePlayer> preparedPlayers =
      PreparedPlaybackStore(
    isUsable: (player) => player.isReusable,
    release: enqueueDispose,
  );
  PlaybackEngineKey engineKey(int index) => PlaybackEngineKey(
        episodes[index].url.trim(),
        revision: preloadManager.sourceRevision,
        variant: preloadManager.preferredDefinition,
        localPath: cachedEpisodePath(index),
      );
  PlaybackCancellation? _preparation;
  PlaybackCancellation? playbackActivation;
  late final PlaybackSession playbackSession = PlaybackSession(
    isLocal: (index) => cachedEpisodePath(index) != null,
    isPreloaded: (index) =>
        preloadManager.isMediaPrefetched(episodes[index].url.trim()),
    run: (index, work, cancellation) => work == PlaybackWork.firstFrame
        ? prepareNextPlayer(index, cancellation: cancellation)
        : _preloadHeader(index, cancellation),
    onError: (error, _) => debugPrint('[PlaybackSDK] 后台任务失败: $error'),
  );

  void startPlaybackSession(int index) {
    playbackSession.start([
      for (var n = 0; n < episodes.length; n++)
        PlaybackSource(episodes[n].url.trim()),
    ], index);
  }

  void cancelPlaybackPreparation() {
    playbackActivation?.cancel();
    playbackSession.cancel();
    _preparation?.cancel();
    preparedPlayers.cancel();
  }

  final List<NativePlayer> _disposeQueue = [];
  bool _draining = false;

  // ─── 宿主须提供 ────────────────────────────────────────────────────────

  List<Episode> get episodes;
  TheaterVideoPreloadManager get preloadManager;
  bool get isOfflinePlayback;
  String? cachedEpisodePath(int index);

  // ─── 销毁队列 ──────────────────────────────────────────────────────────

  void enqueueDispose(NativePlayer player) {
    preparedPlayers.forget(player);
    if (_disposeQueue.contains(player)) return;
    _disposeQueue.add(player);
    _drainDisposeQueue();
  }

  Future<void> _drainDisposeQueue() async {
    if (_draining) return;
    _draining = true;
    while (_disposeQueue.isNotEmpty) {
      final p = _disposeQueue.removeAt(0);
      // 先暂停再销毁，确保音频立即停止
      try {
        await p.pause();
      } catch (e) {
        debugPrint('[Player] 暂停待释放播放器失败: $e');
      } finally {
        try {
          await p.dispose();
        } catch (error) {
          debugPrint('[Player] 释放播放器失败: $error');
        }
      }
    }
    _draining = false;
  }

  // ─── prepareNextPlayer ─────────────────────────────────────────────────

  Future<bool> prepareNextPlayer(int index,
      {PlaybackCancellation? cancellation}) async {
    if (index < 0 || index >= episodes.length) return false;
    if (nextEpisodeIndex == index &&
        nextPlayerReady &&
        nextPlayer != null &&
        preparedPlayers.contains(engineKey(index), nextPlayer!)) {
      return true;
    }
    _preparation?.cancel();
    final token = cancellation ?? PlaybackCancellation();
    _preparation = token;
    final ticket = preparedPlayers.begin(engineKey(index), token);
    void check() {
      token.check();
      if (!mounted ||
          !preparedPlayers.isCurrent(ticket) ||
          index >= episodes.length ||
          ticket.key != engineKey(index)) {
        throw const PlaybackCancelled();
      }
    }

    final episode = episodes[index];
    final videoId = episode.url.trim();
    if (videoId.isEmpty) return false;
    NativePlayer? created;
    var published = false;
    try {
      check();
      String cdnUrl;
      String keyHex = '';
      final localPath = cachedEpisodePath(index);
      if (localPath != null) {
        cdnUrl =
            await token.wait(OfflinePlaybackCache.playableFileUri(localPath));
      } else {
        final url = await token.wait(preloadManager.resolvePlayUrl(videoId,
            forPreload: true, episodeIndex: index, maxRetries: 1));
        await preloadManager.prefetchMedia(videoId, token);
        check();
        if (url.startsWith('crypto://')) {
          final encoded = url.substring('crypto://'.length);
          final split = encoded.indexOf('?key=');
          if (split < 0) return false;
          cdnUrl = Uri.decodeComponent(encoded.substring(0, split));
          keyHex = encoded.substring(split + 5);
        } else {
          // Explicitly unencrypted sources use the same native player.
          cdnUrl = url;
        }
      }
      check();
      if (keyHex.isNotEmpty) {
        // Existing native IO has no abort handle for prewarm. Wait for this
        // bounded operation before allowing the next queued native warm task.
        await CryptoNativeChannel.instance.prewarm(cdnUrl, keyHex);
        check();
      }
      if (nextPlayer != null) enqueueDispose(nextPlayer!);
      nextPlayer = null;
      nextEpisodeIndex = null;
      nextPlayerReady = false;
      final player = NativePlayer();
      created = player;
      await token.wait(player.create(cdnUrl, keyHex));
      check();
      await prepareFirstFrame(
        cancellation: token,
        mute: () => player.setVolume(0),
        prepare: player.prepareFirstFrame,
        waitForFrame: () =>
            player.waitForFirstFrame(timeout: const Duration(seconds: 10)),
        pause: player.pause,
        park: () => player.setActive(false),
      );
      check();
      if (!preparedPlayers.publish(ticket, player)) return false;
      nextPlayer = player;
      nextEpisodeIndex = index;
      nextPlayerReady = true;
      published = true;
      if (mounted) setState(() {});
      debugPrint('[PlaybackSDK] 下一集首帧就绪: 第${index + 1}集');
      return true;
    } on PlaybackCancelled {
      return false;
    } catch (error) {
      debugPrint('[PlaybackSDK] 下一集准备失败: $error');
      return false;
    } finally {
      preparedPlayers.finish(ticket);
      if (identical(_preparation, token)) _preparation = null;
      if (!published && created != null) await created.dispose();
    }
  }

  Future<bool> _preloadHeader(
      int target, PlaybackCancellation cancellation) async {
    if (isOfflinePlayback || target < 0 || target >= episodes.length) {
      return true;
    }
    if (cachedEpisodePath(target) != null) return true;
    return preloadManager.preloadEpisodeHeaderOnly(
      episodes: episodes,
      currentIndex: target - 1,
      targetIndex: target,
      isStillCurrent: () => mounted && !cancellation.isCancelled,
      cancellation: cancellation,
    );
  }

  // ─── 窗口清理 ──────────────────────────────────────────────────────────

  void dispose3PWindow() {
    cancelPlaybackPreparation();
    preparedPlayers.clear();
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
