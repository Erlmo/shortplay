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
  String preferredDefinition = '720p';
  final Map<String, List<FqVideoItem>> _videoItems = {};
  final Map<String, String> _selectedDefinitions = {};

  String selectedDefinition(String videoId) =>
      _selectedDefinitions[videoId] ?? '';

  Future<List<String>> availableDefinitions(String videoId) async {
    final items = _videoItems[videoId] ??
        await apiClient
            .fetchFqVideoModel(videoId)
            .timeout(const Duration(seconds: 10));
    _videoItems[videoId] = items;
    return definitionsFor(items);
  }

  static List<String> definitionsFor(List<FqVideoItem> items) {
    final definitions = items
        .where((item) => item.url.trim().isNotEmpty)
        .map((item) => item.definition.trim().toLowerCase())
        .where((definition) => definition.isNotEmpty)
        .toSet()
        .toList();
    int resolution(String value) =>
        int.tryParse(RegExp(r'\d+').firstMatch(value)?.group(0) ?? '') ?? 0;
    definitions.sort((a, b) {
      final order = resolution(a).compareTo(resolution(b));
      return order == 0 ? a.compareTo(b) : order;
    });
    return List.unmodifiable(definitions);
  }

  void setPreferredDefinition(String definition) {
    if (definition.trim().isNotEmpty) preferredDefinition = definition;
    clear();
  }

  final Set<int> _preloadingEpisodeIndexes = {};

  // 已解析的播放信息（地址 + key），预加载与正式播放共用，保证 native
  // 预热缓存的 key（CDN url）前后一致。
  final Map<String, _ResolvedTheaterVideo> _resolved = {};

  // 已完成的预热级别（按 videoId）。以前用 _preloadedUrls 判断“已预加载”，
  // 但地址解析成功 ≠ 预热完成：预热被跳过/失败后这一集再也不会重试，
  // 只做过 header-only 的集也永远拿不到 mdat 种子。
  final Set<String> _fullPrewarmed = {};
  final Set<String> _headerPrewarmed = {};

  // 预热串行队列：同一时刻只跑一个 native prewarm（弱网下不占满连接池、
  // 不和当前集抢带宽），但任务是排队而不是丢弃——以前忙时直接 return，
  // 这一集的预热就永久丢失了。N+1 的预热在 prepareNextPlayer 里直接调用、
  // 不进这个队列，相当于更高优先级。
  Future<void> _prewarmTail = Future<void>.value();
  int _generation = 0;

  Future<int> _enqueuePrewarm(Future<int> Function() task) {
    final completer = Completer<int>();
    _prewarmTail = _prewarmTail.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  /// 清掉解析与预热记录。[keepVideoIds] 里的视频保留：切到下一季时首集已经
  /// 提前预热过，保留它的解析结果（CDN 地址）才能命中 native 预热缓存。
  void clear({Iterable<String> keepVideoIds = const []}) {
    _generation++;
    final keep = keepVideoIds.toSet();
    bool drop(String videoId) => !keep.contains(videoId);
    _preloadedUrls.removeWhere((videoId, _) => drop(videoId));
    _sourceUrls.removeWhere((videoId, _) => drop(videoId));
    _resolved.removeWhere((videoId, _) => drop(videoId));
    _fullPrewarmed.removeWhere(drop);
    _headerPrewarmed.removeWhere(drop);
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

  /// 解析（或复用已解析的）播放信息。首次结果被固定下来：之后不会再用
  /// 新签名的 CDN url 覆盖，否则 native 预热缓存（以 CDN url 为 key）会失配。
  Future<_ResolvedTheaterVideo> _resolveCached(
    String videoId, {
    int maxRetries = 3,
  }) async {
    final cached = _resolved[videoId];
    if (cached != null) return cached;
    final fresh = await _resolveVideoWithRetry(videoId, maxRetries: maxRetries);
    final kept = _resolved.putIfAbsent(videoId, () => fresh);
    _preloadedUrls.putIfAbsent(videoId, () => kept.proxyUrl);
    _sourceUrls.putIfAbsent(videoId, () => kept.sourceUrl);
    return kept;
  }

  Future<String> resolvePlayUrl(
    String videoId, {
    required int episodeIndex,
    int maxRetries = 3,
  }) async {
    if (_resolved.containsKey(videoId)) {
      debugPrint('使用预加载缓存，秒开');
    }
    final resolved = await _resolveCached(videoId, maxRetries: maxRetries);
    debugPrint('播放地址就绪');
    return resolved.proxyUrl;
  }

  /// 完整预热：文件头 + 样本表 + mdat 种子。对只做过 header-only 的集，
  /// native 侧会补上 mdat 种子。
  Future<void> preloadEpisode({
    required List<Episode> episodes,
    required int currentIndex,
    required int targetIndex,
    required bool Function() isStillCurrent,
    VoidCallback? onNextEpisodeReady,
  }) async {
    final ok = await _prewarmEpisode(
      episodes: episodes,
      targetIndex: targetIndex,
      isStillCurrent: isStillCurrent,
      headerOnly: false,
    );
    if (ok && targetIndex == currentIndex + 1) {
      onNextEpisodeReady?.call();
    }
  }

  /// 只预热文件头 + 样本表（不拉 mdat），用于更远的集。
  Future<void> preloadEpisodeHeaderOnly({
    required List<Episode> episodes,
    required int currentIndex,
    required int targetIndex,
    required bool Function() isStillCurrent,
  }) async {
    await _prewarmEpisode(
      episodes: episodes,
      targetIndex: targetIndex,
      isStillCurrent: isStillCurrent,
      headerOnly: true,
    );
  }

  Future<bool> _prewarmEpisode({
    required List<Episode> episodes,
    required int targetIndex,
    required bool Function() isStillCurrent,
    required bool headerOnly,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return false;
    if (_preloadingEpisodeIndexes.contains(targetIndex)) return false;

    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty) return false;
    final done = headerOnly ? _headerPrewarmed : _fullPrewarmed;
    if (done.contains(videoId)) return true;

    final label = headerOnly ? '剧集头部数据预缓存' : '剧集数据预缓存';
    final gen = _generation;
    bool stale() => !isStillCurrent() || gen != _generation;

    _preloadingEpisodeIndexes.add(targetIndex);
    try {
      if (stale()) return false;
      final resolved = await _resolveCached(videoId);
      if (stale()) return false;

      final status = await _enqueuePrewarm(() async {
        // 排队期间可能已离开页面或切换清晰度，过期任务直接跳过。
        if (stale()) return -2;
        return headerOnly
            ? CryptoNativeChannel.instance
                .prewarmHeaderOnly(resolved.sourceUrl, resolved.key)
            : CryptoNativeChannel.instance
                .prewarm(resolved.sourceUrl, resolved.key);
      });
      if (status == -2) return false;
      if (status != 0) {
        debugPrint('$label 返回非零状态: $status (第${targetIndex + 1}集)');
        return false;
      }
      if (gen == _generation) {
        _headerPrewarmed.add(videoId);
        if (!headerOnly) _fullPrewarmed.add(videoId);
      }
      debugPrint('$label完成: 第${targetIndex + 1}集');
      return true;
    } catch (error) {
      debugPrint('$label失败 第${targetIndex + 1}集: $error');
      return false;
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
      final status =
          await CryptoNativeChannel.instance.prewarmSeedMdat(sourceUrl);
      if (status != 0) {
        debugPrint(
            'native prewarmSeedMdat 返回非零: $status (第${targetIndex + 1}集)');
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

    _videoItems[videoId] = videoItems;
    final selected = _selectBestVideo(
        videoItems.where((item) => item.url.trim().isNotEmpty).toList());
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

    _selectedDefinitions[videoId] = selected.definition.trim().toLowerCase();
    return _ResolvedTheaterVideo(
      proxyUrl: playUrl,
      sourceUrl: selected.url,
      key: key,
    );
  }

  FqVideoItem _selectBestVideo(List<FqVideoItem> items) {
    return items.firstWhere(
      (item) =>
          item.definition.trim().toLowerCase() ==
          preferredDefinition.trim().toLowerCase(),
      orElse: () => items.firstWhere(
        (item) => item.definition == '1080p',
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
