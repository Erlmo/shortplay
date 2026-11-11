import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

import '../config/api_config.dart';
import '../models/episode.dart';
import '../models/fq_video.dart';
import 'api_client.dart';
import 'crypto_native_channel.dart';
import 'playback_media_cache.dart';
import 'playback_network_sources.dart';
import 'playback_policy_service.dart';
import 'playback_preferences.dart';

class TheaterVideoPreloadManager {
  TheaterVideoPreloadManager({
    required this.apiClient,
    Future<MediaDownloader?> Function()? mediaDownloader,
    Future<void> Function(FqVideoItem)? configureNetwork,
    double? Function()? targetBitrateProvider,
    bool Function(FqVideoItem)? hasCachedMedia,
    List<String>? allowedDefinitions,
    PlaybackPolicyService? playbackPolicies,
  })  : _mediaDownloader =
            mediaDownloader ?? (() => PlaybackMediaCache.instance),
        _configureNetwork =
            configureNetwork ?? PlaybackNetworkSources.configure,
        _targetBitrateProvider = targetBitrateProvider,
        _hasCachedMedia = hasCachedMedia ??
            ((item) =>
                PlaybackMediaCache.ready?.cache.hasVerifiedMedia(item.url) ??
                false),
        _allowedDefinitions = allowedDefinitions,
        _playbackPolicies = playbackPolicies ?? apiClient.playbackPolicies;

  final Future<MediaDownloader?> Function() _mediaDownloader;
  final Future<void> Function(FqVideoItem) _configureNetwork;

  final ApiClient apiClient;
  final double? Function()? _targetBitrateProvider;
  final bool Function(FqVideoItem) _hasCachedMedia;
  final List<String>? _allowedDefinitions;
  final PlaybackPolicyService _playbackPolicies;
  bool _manualQuality = false;
  String _defaultPreference = 'auto';

  void _syncDefaultPreference() {
    final value = PlaybackPreferences.defaultDefinition.value;
    if (value == _defaultPreference) return;
    _defaultPreference = value;
    if (_manualQuality) return;
    preferredDefinition = value == 'auto' ? '720p' : value;
    _generation++;
    _resolved.clear();
    _preloading.clear();
  }

  bool get adaptiveQualityAvailable =>
      !_manualQuality &&
      PlaybackPreferences.defaultDefinition.value == 'auto' &&
      _targetBitrateProvider != null;
  final _models = PlaybackResourceCache<String, List<FqVideoItem>>(
    capacity: 16,
    isValid: (items) =>
        items.isNotEmpty &&
        items.every((item) =>
            item.cacheable &&
            (item.expiresAt == null ||
                item.expiresAt!
                    .isAfter(DateTime.now().add(const Duration(seconds: 30))))),
  );

  String preferredDefinition = '720p';

  // One bounded entry owns the URL, selected quality and warm state. This keeps
  // signing/quality changes from accidentally mixing native cache identities.
  final _resolved = PlaybackResourceCache<String, _ResolvedTheaterVideo>(
    capacity: 16,
    isValid: (value) =>
        value.cacheable &&
        (value.expiresAt == null ||
            value.expiresAt!
                .isAfter(DateTime.now().add(const Duration(seconds: 30)))),
  );

  String selectedDefinition(String videoId) =>
      _resolved.get(videoId)?.definition ?? '';

  Future<List<String>> availableDefinitions(String videoId) async =>
      definitionsFor((await _resolveCached(videoId)).items);

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

  void setPreferredDefinition(String definition, {String? keepVideoId}) {
    if (definition.trim().isEmpty) return;
    preferredDefinition = definition.trim().toLowerCase();
    _manualQuality = true;
    _generation++;
    _resolved.retainWhere((key) => key == keepVideoId);
    _preloading.clear();
  }

  /// The host must supply a real target predictor before enabling adaptive
  /// startup/preload selection. This never starts a continuous MP4 switch loop.
  void useAutomaticQuality() {
    _manualQuality = false;
    _generation++;
    _resolved.clear();
    _preloading.clear();
  }

  final Map<String, Object> _preloading = {};

  // Native prewarm calls cannot currently be interrupted inside the platform
  // channel. Serialize them; cancelled queued work is skipped before entering.
  Future<void> _prewarmTail = Future<void>.value();
  int _generation = 0;
  int get sourceRevision => _generation;

  bool isMediaPrefetched(String videoId) =>
      _resolved.get(videoId)?.mediaPrefetched ?? false;

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
    _resolved.retainWhere(keep.contains);
    _models.retainWhere(keep.contains);
    _preloading.clear();
  }

  bool isNextEpisodeReady({
    required List<Episode> episodes,
    required int currentIndex,
  }) {
    final next = currentIndex + 1;
    if (next >= episodes.length) return true;
    return _resolved.get(episodes[next].url.trim()) != null;
  }

  Future<_ResolvedTheaterVideo> _resolveCached(
    String videoId, {
    int maxRetries = 3,
    bool forPreload = false,
    int episodeIndex = -1,
  }) {
    _syncDefaultPreference();
    return _resolved.load(
        videoId,
        () => _resolveVideoWithRetry(videoId,
            maxRetries: maxRetries,
            forPreload: forPreload,
            episodeIndex: episodeIndex));
  }

  Future<String> resolvePlayUrl(
    String videoId, {
    required int episodeIndex,
    int maxRetries = 3,
    bool forPreload = false,
  }) async {
    final resolved = await _resolveCached(videoId,
        maxRetries: maxRetries,
        forPreload: forPreload,
        episodeIndex: episodeIndex + 1);
    debugPrint('播放地址就绪');
    return resolved.proxyUrl;
  }

  /// Download the same raw media blocks that native playback will consume.
  /// Failure is a cache miss: foreground/native reads retain their own fallback.
  Future<void> prefetchMedia(
      String videoId, PlaybackCancellation cancellation) async {
    cancellation.check();
    final resolved = _resolved.get(videoId);
    if (resolved != null) await _prefetchResolved(resolved, cancellation);
  }

  Future<bool> _prefetchResolved(
      _ResolvedTheaterVideo resolved, PlaybackCancellation cancellation) async {
    try {
      cancellation.check();
      final downloader = await cancellation.wait(_mediaDownloader());
      if (downloader == null) return false;
      final info = await downloader.prefetch(resolved.sourceUrl,
          cancellation: cancellation, expiresAt: resolved.expiresAt);
      final complete = info.totalLength > 0 &&
          info.cachedBytesFromZero >=
              (info.totalLength < 800 * 1024 ? info.totalLength : 800 * 1024);
      resolved.mediaPrefetched = complete;
      return complete;
    } on PlaybackCancelled {
      rethrow;
    } catch (error) {
      debugPrint('[PlaybackSDK] 媒体字节预取失败，保留原生读取兜底: $error');
      return false;
    }
  }

  /// 完整预热：文件头 + 样本表 + mdat 种子。对只做过 header-only 的集，
  /// native 侧会补上 mdat 种子。
  Future<void> preloadEpisode({
    required List<Episode> episodes,
    required int currentIndex,
    required int targetIndex,
    required bool Function() isStillCurrent,
    VoidCallback? onNextEpisodeReady,
    PlaybackCancellation? cancellation,
  }) async {
    final ok = await _prewarmEpisode(
      episodes: episodes,
      targetIndex: targetIndex,
      isStillCurrent: isStillCurrent,
      headerOnly: false,
      cancellation: cancellation,
    );
    if (ok && targetIndex == currentIndex + 1) {
      onNextEpisodeReady?.call();
    }
  }

  /// 只预热文件头 + 样本表（不拉 mdat），用于更远的集。
  Future<bool> preloadEpisodeHeaderOnly({
    required List<Episode> episodes,
    required int currentIndex,
    required int targetIndex,
    required bool Function() isStillCurrent,
    PlaybackCancellation? cancellation,
  }) async {
    return _prewarmEpisode(
      episodes: episodes,
      targetIndex: targetIndex,
      isStillCurrent: isStillCurrent,
      headerOnly: true,
      cancellation: cancellation,
    );
  }

  Future<bool> _prewarmEpisode({
    required List<Episode> episodes,
    required int targetIndex,
    required bool Function() isStillCurrent,
    required bool headerOnly,
    PlaybackCancellation? cancellation,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return false;

    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty) return false;
    if (_preloading.containsKey(videoId)) return false;

    final label = headerOnly ? '剧集头部数据预缓存' : '剧集数据预缓存';
    final gen = _generation;
    bool stale() => !isStillCurrent() || gen != _generation;

    final pending = Object();
    _preloading[videoId] = pending;
    try {
      if (stale()) return false;
      final resolved = await _resolveCached(videoId,
          maxRetries: 1, forPreload: true, episodeIndex: targetIndex + 1);
      if (stale()) return false;
      final prefetched = await _prefetchResolved(
          resolved, cancellation ?? PlaybackCancellation());
      if (stale()) return false;
      if (headerOnly ? resolved.headerWarmed : resolved.fullWarmed) return true;

      // Clear and encrypted sources now share the same raw byte cache.
      if (resolved.key.isEmpty) return prefetched || headerOnly;
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
        resolved.headerWarmed = true;
        if (!headerOnly) resolved.fullWarmed = true;
      }
      debugPrint('$label完成: 第${targetIndex + 1}集');
      return true;
    } catch (error) {
      debugPrint('$label失败 第${targetIndex + 1}集: $error');
      return false;
    } finally {
      if (identical(_preloading[videoId], pending)) _preloading.remove(videoId);
    }
  }

  Future<void> seedMdat({
    required List<Episode> episodes,
    required int targetIndex,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return;
    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty) return;

    final resolved = _resolved.get(videoId);
    if (resolved == null || resolved.key.isEmpty) return;
    final sourceUrl = resolved.sourceUrl;

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
    bool forPreload = false,
    int episodeIndex = -1,
  }) async {
    int attempt = 0;
    while (attempt < maxRetries) {
      try {
        attempt++;
        return await _resolveVideo(videoId,
            forPreload: forPreload, episodeIndex: episodeIndex);
      } on TimeoutException catch (error) {
        debugPrint('解析视频超时 (尝试 $attempt/$maxRetries): $error');
        if (attempt >= maxRetries) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      } catch (error) {
        debugPrint('解析视频失败 (尝试 $attempt/$maxRetries): $error');
        if (attempt >= maxRetries ||
            error is! ApiException ||
            !error.retryable) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw Exception('解析视频失败：已重试$maxRetries次');
  }

  Future<_ResolvedTheaterVideo> _resolveVideo(String videoId,
      {required bool forPreload, required int episodeIndex}) async {
    final generation = _generation;
    final preferred = preferredDefinition;
    final manual = _manualQuality || _defaultPreference != 'auto';
    final videoItems = await _models.load(
        videoId,
        () async => List.unmodifiable(await apiClient
            .fetchFqVideoModel(videoId)
            .timeout(ApiConfig.videoResolutionTimeout)));
    if (videoItems.isEmpty) {
      throw Exception('未获取到视频信息');
    }

    final selected = _selectBestVideo(
        videoItems.where((item) => item.url.trim().isNotEmpty).toList(),
        preferred: preferred,
        manual: manual,
        forPreload: forPreload,
        episodeIndex: episodeIndex);
    debugPrint(
      '选择画质: ${selected.definition} ${selected.width}x${selected.height} codec=${selected.codec}',
    );

    final key = !selected.isEncrypted
        ? ''
        : selected.decryptKey.isNotEmpty
            ? selected.decryptKey
            : await apiClient
                .fetchDecryptKey(selected.spadeA)
                .timeout(const Duration(seconds: 5));
    debugPrint(selected.isEncrypted ? '获取视频解密参数成功' : '视频无需解密，直接播放');

    if (generation == _generation) await _configureNetwork(selected);

    // Decrypt in the player IO pipeline via the native crypto:// protocol
    // (no localhost proxy).
    final playUrl = key.isEmpty
        ? selected.url
        : CryptoNativeChannel.buildCryptoUrl(selected.url, key);

    return _ResolvedTheaterVideo(
      definition: selected.definition.trim().toLowerCase(),
      items: List.unmodifiable(videoItems),
      proxyUrl: playUrl,
      sourceUrl: selected.url,
      key: key,
      expiresAt: selected.expiresAt,
      cacheable: selected.cacheable,
    );
  }

  FqVideoItem _selectBestVideo(List<FqVideoItem> items,
      {required String preferred,
      required bool manual,
      required bool forPreload,
      required int episodeIndex}) {
    if (items.isEmpty) throw StateError('没有可用清晰度');
    // Keep one complete, compatible representation per definition. A cache hit
    // for a different codec/key must not be grafted onto the first variant.
    final byDefinition = <String, FqVideoItem>{};
    for (final item in items) {
      byDefinition.putIfAbsent(
          item.definition.trim().toLowerCase(), () => item);
    }
    final supported = byDefinition.keys.toList();
    // The host's available variants have already passed ApiClient codec checks.
    final hostAllowed =
        _allowedDefinitions ?? DramaQualitySelector.defaultAllowed;
    final allowed = manual
        ? hostAllowed
        : _playbackPolicies.allowedDefinitions(hostAllowed);
    String? cached;
    if (!manual && _playbackPolicies.preferCache) {
      cached = DramaQualitySelector.cached(
          supported: supported,
          hasCachedMedia: (definition) {
            try {
              return _hasCachedMedia(byDefinition[definition]!);
            } catch (error) {
              debugPrint('[PlaybackSDK] 缓存档位不可用: $error');
              return false;
            }
          });
    }
    String? strategy;
    final renditions = [
      for (final item in items)
        QualityRendition(item.definition, item.bitrate, item)
    ];
    if (!manual &&
        _targetBitrateProvider != null &&
        !_playbackPolicies.hasSettings) {
      double? target;
      try {
        target = _targetBitrateProvider();
      } catch (error) {
        debugPrint('[PlaybackSDK] 目标码率不可用，保持默认档位: $error');
      }
      final fallback = renditions.firstWhere(
          (item) => item.definition.trim().toLowerCase() == '720p',
          orElse: () => renditions.first);
      strategy =
          PlaybackQualitySelector.byTargetBitrate(renditions, target, fallback)
              .definition
              .trim()
              .toLowerCase();
    }
    if (!manual && cached == null) {
      final remote = _playbackPolicies.evaluate(
          renditions: [
            for (final item in items)
              RemoteDramaRendition(item.definition.toUpperCase(), item.bitrate)
          ],
          allowedDefinitions:
              allowed.map((value) => value.toUpperCase()).toList(),
          episodeIndex: episodeIndex,
          isPreload: forPreload);
      if (remote != null) {
        strategy = remote.definition?.toLowerCase();
        if (!remote.isResolved) {
          debugPrint(
              '[PlaybackSDK] 策略缺少实际观测，保留默认档位: ${remote.missingInputs.join(',')}');
        }
      }
    }
    final definition = forPreload
        ? DramaQualitySelector.preload(
            supported: supported,
            allowed: allowed,
            manual: manual ? preferred : null,
            cached: cached,
            strategy: strategy ?? preferred)
        : DramaQualitySelector.playback(
            supported: supported,
            allowed: allowed,
            manual: manual ? preferred : null,
            cached: cached,
            strategy: strategy ?? preferred);
    // A native engine can retain its old/default resolution when there is no
    // intersection. This host must open an actual URL, so retain a valid model.
    return byDefinition[definition] ?? items.first;
  }
}

class _ResolvedTheaterVideo {
  _ResolvedTheaterVideo({
    required this.definition,
    required this.items,
    required this.proxyUrl,
    required this.sourceUrl,
    required this.key,
    this.expiresAt,
    this.cacheable = true,
  });

  final String definition;
  final List<FqVideoItem> items;
  bool mediaPrefetched = false;
  bool headerWarmed = false;
  bool fullWarmed = false;
  final String proxyUrl;
  final String sourceUrl;
  final String key;
  final DateTime? expiresAt;
  final bool cacheable;
}
