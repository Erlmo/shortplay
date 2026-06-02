import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/fq_video.dart';
import 'api_client.dart';
import 'crypto_native_channel.dart';

class TheaterVideoPreloadManager {
  TheaterVideoPreloadManager({
    required this.apiClient,
  });

  final ApiClient apiClient;

  final Map<String, String> _preloadedUrls = {};
  final Map<String, String> _sourceUrls = {};
  final Set<int> _preloadingEpisodeIndexes = {};
  int _activePrewarmCount = 0;
  static const _maxConcurrentPrewarms = 1;

  void clear() {
    _preloadedUrls.clear();
    _sourceUrls.clear();
    _preloadingEpisodeIndexes.clear();
  }

  bool isNextEpisodeReady({
    required List<Episode> episodes,
    required int currentIndex,
  }) {
    final nextIndex = currentIndex + 1;
    if (nextIndex >= episodes.length) return true;
    final videoId = episodes[nextIndex].url.trim();
    return videoId.isNotEmpty && _preloadedUrls.containsKey(videoId);
  }

  Future<String> resolvePlayUrl(
    String videoId, {
    required int episodeIndex,
    int maxRetries = 3,
  }) async {
    final cachedUrl = _preloadedUrls[videoId];
    if (cachedUrl != null) {
      debugPrint('使用预加载缓存，秒开');
      return cachedUrl;
    }

    final resolved = await _resolveVideoWithRetry(videoId, maxRetries: maxRetries);
    _preloadedUrls[videoId] = resolved.proxyUrl;
    // putIfAbsent：保留第一次存入的 sourceUrl（来自 preloadEpisode /
    // preloadEpisodeHeaderOnly），不让后续 resolvePlayUrl 覆盖它。
    // native prewarm 缓存以 CDN URL 为 key，覆盖后 seedMdat 会用新 URL
    // 而 prewarm 缓存里存的是旧 URL，导致 prewarmSeedMdat 返回非零。
    _sourceUrls.putIfAbsent(videoId, () => resolved.sourceUrl);
    debugPrint('播放地址就绪');
    return resolved.proxyUrl;
  }

  Future<void> preloadEpisode({
    required List<Episode> episodes,
    required int currentIndex,
    required int targetIndex,
    required bool Function() isStillCurrent,
    VoidCallback? onNextEpisodeReady,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return;
    if (_preloadingEpisodeIndexes.contains(targetIndex)) return;

    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty || _preloadedUrls.containsKey(videoId)) return;

    _preloadingEpisodeIndexes.add(targetIndex);
    try {
      if (!isStillCurrent()) return;
      final resolved = await _resolveVideoWithRetry(videoId);
      if (!isStillCurrent()) return;

      _preloadedUrls[videoId] = resolved.proxyUrl;
      // putIfAbsent：保留第一次存入的 sourceUrl（来自 preloadEpisode /
      // preloadEpisodeHeaderOnly），不让后续 resolvePlayUrl 覆盖它。
      // native prewarm 缓存以 CDN URL 为 key，覆盖后 seedMdat 会用新 URL
      // 而 prewarm 缓存里存的是旧 URL，导致 prewarmSeedMdat 返回非零。
      _sourceUrls.putIfAbsent(videoId, () => resolved.sourceUrl);
      // Prewarm the native crypto:// pipeline so the next cb_open skips the
      // ~300-680ms box scan + header fetch + sample parse (header + sample
      // table get cached in the C core, keyed by CDN url).
      if (!isStillCurrent()) return;
      // 限制同时进行的 prewarm 数量，避免弱网下占满连接池影响当前集播放
      if (_activePrewarmCount >= _maxConcurrentPrewarms) return;
      _activePrewarmCount++;
      try {
        final status = await CryptoNativeChannel.instance
            .prewarm(resolved.sourceUrl, resolved.key);
        if (status != 0) {
          debugPrint('native prewarm 返回非零状态: $status (第${targetIndex + 1}集)');
        }
      } finally {
        _activePrewarmCount--;
      }
      debugPrint('剧集数据预缓存完成: 第${targetIndex + 1}集');

      if (targetIndex == currentIndex + 1) {
        onNextEpisodeReady?.call();
      }
    } catch (error) {
      debugPrint('第${targetIndex + 1}集预缓存失败: $error');
    } finally {
      _preloadingEpisodeIndexes.remove(targetIndex);
    }
  }

  // 带重试的视频解析：首集播放与预加载共用，消除“首集有重试、预加载无重试”
  // 的不对称——慢网下预加载也能像首集一样重试兜底，不会一次超时就放弃。
  Future<void> preloadEpisodeHeaderOnly({
    required List<Episode> episodes,
    required int currentIndex,
    required int targetIndex,
    required bool Function() isStillCurrent,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return;
    if (_preloadingEpisodeIndexes.contains(targetIndex)) return;

    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty || _preloadedUrls.containsKey(videoId)) return;

    _preloadingEpisodeIndexes.add(targetIndex);
    try {
      if (!isStillCurrent()) return;
      final resolved = await _resolveVideoWithRetry(videoId);
      if (!isStillCurrent()) return;

      _preloadedUrls[videoId] = resolved.proxyUrl;
      _sourceUrls.putIfAbsent(videoId, () => resolved.sourceUrl);
      if (!isStillCurrent()) return;
      if (_activePrewarmCount >= _maxConcurrentPrewarms) return;
      _activePrewarmCount++;
      try {
        final status = await CryptoNativeChannel.instance
            .prewarmHeaderOnly(resolved.sourceUrl, resolved.key);
        if (status != 0) {
          debugPrint('native prewarmHeaderOnly 返回非零: $status (第${targetIndex + 1}集)');
        }
      } finally {
        _activePrewarmCount--;
      }
      debugPrint('剧集头部数据预缓存完成: 第${targetIndex + 1}集');
    } catch (error) {
      debugPrint('预加载头部失败 第${targetIndex + 1}集: $error');
    } finally {
      _preloadingEpisodeIndexes.remove(targetIndex);
    }
  }

  Future<void> seedMdat({
    required List<Episode> episodes,
    required int targetIndex,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return;
    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty) return;

    final sourceUrl = _sourceUrls[videoId];
    if (sourceUrl == null) return;

    try {
      final status = await CryptoNativeChannel.instance
          .prewarmSeedMdat(sourceUrl);
      if (status != 0) {
        debugPrint('native prewarmSeedMdat 返回非零: $status (第${targetIndex + 1}集)');
      } else {
        debugPrint('剧集mdat种子补充完成: 第${targetIndex + 1}集');
      }
    } catch (error) {
      debugPrint('seedMdat失败 第${targetIndex + 1}集: $error');
    }
  }

  Future<_ResolvedTheaterVideo> _resolveVideoWithRetry(
    String videoId, {
    int maxRetries = 3,
  }) async {
    int attempt = 0;
    while (attempt < maxRetries) {
      try {
        attempt++;
        return await _resolveVideo(videoId);
      } on TimeoutException catch (error) {
        debugPrint('解析视频超时 (尝试 $attempt/$maxRetries): $error');
        if (attempt >= maxRetries) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      } catch (error) {
        debugPrint('解析视频失败 (尝试 $attempt/$maxRetries): $error');
        if (attempt >= maxRetries) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw Exception('解析视频失败：已重试$maxRetries次');
  }

  Future<_ResolvedTheaterVideo> _resolveVideo(String videoId) async {
    final videoItems = await apiClient
        .fetchFqVideoModel(videoId)
        .timeout(const Duration(seconds: 10));
    if (videoItems.isEmpty) {
      throw Exception('未获取到视频信息');
    }

    final selected = _selectBestVideo(videoItems);
    debugPrint(
      '选择画质: ${selected.definition} ${selected.width}x${selected.height} codec=${selected.codec}',
    );

    final key = await apiClient
        .fetchDecryptKey(selected.spadeA)
        .timeout(const Duration(seconds: 5));
    debugPrint('获取key成功: ${key.substring(0, 8)}...');

    // Decrypt in the player IO pipeline via the native crypto:// protocol
    // (no localhost proxy).
    final playUrl = CryptoNativeChannel.buildCryptoUrl(selected.url, key);

    return _ResolvedTheaterVideo(
      proxyUrl: playUrl,
      sourceUrl: selected.url,
      key: key,
    );
  }

  FqVideoItem _selectBestVideo(List<FqVideoItem> items) {
    return items.firstWhere(
      (item) => item.definition == '1080p',
      orElse: () => items.firstWhere(
        (item) => item.definition == '720p',
        orElse: () => items.last,
      ),
    );
  }
}

class _ResolvedTheaterVideo {
  const _ResolvedTheaterVideo({
    required this.proxyUrl,
    required this.sourceUrl,
    required this.key,
  });

  final String proxyUrl;
  final String sourceUrl;
  final String key;
}
