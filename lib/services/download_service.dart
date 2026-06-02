import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/episode.dart';
import '../services/api_client.dart';
import 'crypto_native_channel.dart';

enum DownloadStatus { pending, downloading, paused, completed, failed }

/// 下载所需的解析结果：CDN 源地址 + 解密 key
class DownloadResolveResult {
  const DownloadResolveResult({required this.cdnUrl, required this.keyHex});

  final String cdnUrl;
  final String keyHex;
}

class EpisodeDownload {
  EpisodeDownload({
    required this.dramaId,
    required this.dramaName,
    required this.episode,
    this.status = DownloadStatus.pending,
    this.progress = 0.0,
    this.localPath,
    this.error,
  });

  final String dramaId;
  final String dramaName;
  final Episode episode;
  DownloadStatus status;
  double progress;
  String? localPath;
  String? error;

  String get key => '${dramaId}_${episode.index}';
}

class DramaDownloadGroup {
  DramaDownloadGroup({
    required this.dramaId,
    required this.dramaName,
    required this.episodes,
    this.coverUrl,
    this.localCoverPath,
    this.isTheaterResource = false,
  });

  final String dramaId;
  final String dramaName;
  final List<EpisodeDownload> episodes;
  final String? coverUrl;
  String? localCoverPath;
  final bool isTheaterResource;

  int get completedCount =>
      episodes.where((e) => e.status == DownloadStatus.completed).length;
  int get totalCount => episodes.length;
  bool get isAllCompleted => completedCount == totalCount;
}

class DownloadService extends ChangeNotifier {
  static const int _concurrency = 3;
  static const String _prefsGroupsKey = 'download_groups_v2';
  static const String _prefsCompletedKey = 'download_completed_keys';

  Timer? _saveDebounce;

  final ApiClient apiClient;
  // Dio 仅用于封面图下载
  final _dio = Dio();
  SharedPreferences? _prefs;

  final Map<String, DramaDownloadGroup> _groups = {};
  final Set<String> _activeKeys = {};
  final Set<String> _completedKeys = {};
  final Set<String> _pausedKeys = {};
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  // key -> resolveUrl function（resume 时复用）
  final Map<String, Future<DownloadResolveResult> Function(Episode)>
  _resolvers = {};

  DownloadService({required this.apiClient}) {
    _init();
  }

  bool _loaded = false;
  bool get loaded => _loaded;
  Completer<void>? _loadCompleter;

  Future<void> _init() async {
    _loadCompleter = Completer<void>();
    await _loadState();
    _loaded = true;
    _loadCompleter!.complete();
    notifyListeners();
  }

  /// 等待初始化完成
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await _loadCompleter?.future;
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _dio.close(force: true);
    super.dispose();
  }

  Map<String, DramaDownloadGroup> get groups => Map.unmodifiable(_groups);

  // ── Persistence ──────────────────────────────────────────────

  Future<void> _loadState() async {
    _prefs = await SharedPreferences.getInstance();
    final prefs = _prefs!;

    final completedKeys = prefs.getStringList(_prefsCompletedKey) ?? [];
    _completedKeys.addAll(completedKeys);

    final groupsJson = prefs.getStringList(_prefsGroupsKey) ?? [];
    final base = await getApplicationDocumentsDirectory();

    for (final jsonStr in groupsJson) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        final dramaId = map['dramaId'] as String;
        final dramaName = map['dramaName'] as String;
        final coverUrl = map['coverUrl'] as String?;
        final isTheaterResource = map['isTheaterResource'] as bool? ?? false;
        final dir = Directory('${base.path}/downloads/$dramaId');

        final coverPath = '${dir.path}/cover.jpg';
        final localCoverPath = File(coverPath).existsSync() ? coverPath : null;

        final episodesList =
            (map['episodes'] as List).cast<Map<String, dynamic>>();
        final episodes = <EpisodeDownload>[];

        for (final epMap in episodesList) {
          final index = epMap['index'] as int;
          final name = epMap['name'] as String? ?? '';
          final size = epMap['size'] as int? ?? 0;
          final url = epMap['url'] as String? ?? '';
          final ep = Episode(index: index, name: name, size: size, url: url);
          final epKey = '${dramaId}_$index';
          final localPath = '${dir.path}/ep_$index.mp4';
          final fileExists = File(localPath).existsSync();
          final isCompleted = _completedKeys.contains(epKey) && fileExists;

          episodes.add(
            EpisodeDownload(
              dramaId: dramaId,
              dramaName: dramaName,
              episode: ep,
              status:
                  isCompleted ? DownloadStatus.completed : DownloadStatus.paused,
              localPath: isCompleted ? localPath : null,
            ),
          );
          if (!isCompleted) _pausedKeys.add(epKey);
        }

        _groups[dramaId] = DramaDownloadGroup(
          dramaId: dramaId,
          dramaName: dramaName,
          episodes: episodes,
          coverUrl: coverUrl,
          localCoverPath: localCoverPath,
          isTheaterResource: isTheaterResource,
        );
      } on Exception catch (e) {
        debugPrint('DownloadService: failed to parse group: $e');
      }
    }

    notifyListeners();
  }

  Future<void> _saveGroups() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final list = _groups.values.map((g) {
      return jsonEncode({
        'dramaId': g.dramaId,
        'dramaName': g.dramaName,
        'coverUrl': g.coverUrl,
        'isTheaterResource': g.isTheaterResource,
        'episodes': g.episodes
            .map(
              (e) => {
                'index': e.episode.index,
                'name': e.episode.name,
                'size': e.episode.size,
                'url': e.episode.url,
              },
            )
            .toList(),
      });
    }).toList();
    await prefs.setStringList(_prefsGroupsKey, list);
  }

  void _scheduleSaveGroups() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 5), _saveGroups);
  }

  Future<void> _saveCompletedKeys() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsCompletedKey, _completedKeys.toList());
  }

  // ── Directory ─────────────────────────────────────────────────

  Future<Directory> _dramaDir(String dramaId) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads/$dramaId');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // ── Public API ────────────────────────────────────────────────

  Future<void> addDownloads({
    required String dramaId,
    required String dramaName,
    required List<Episode> episodes,
    required Future<DownloadResolveResult> Function(Episode) resolveUrl,
    String? coverUrl,
    bool isTheaterResource = false,
  }) async {
    await ensureLoaded();
    final group = _groups.putIfAbsent(
      dramaId,
      () => DramaDownloadGroup(
        dramaId: dramaId,
        dramaName: dramaName,
        episodes: [],
        coverUrl: coverUrl,
        isTheaterResource: isTheaterResource,
      ),
    );

    if (coverUrl != null &&
        coverUrl.isNotEmpty &&
        group.localCoverPath == null) {
      _downloadCover(group, coverUrl);
    }

    for (final ep in episodes) {
      final epKey = '${dramaId}_${ep.index}';
      if (group.episodes.any((e) => e.key == epKey)) continue;
      final dl = EpisodeDownload(
        dramaId: dramaId,
        dramaName: dramaName,
        episode: ep,
        status: _completedKeys.contains(epKey)
            ? DownloadStatus.completed
            : DownloadStatus.pending,
      );
      if (_completedKeys.contains(epKey)) {
        final dir = await _dramaDir(dramaId);
        dl.localPath = '${dir.path}/ep_${ep.index}.mp4';
      }
      group.episodes.add(dl);
      _resolvers[epKey] = resolveUrl;
    }

    _scheduleSaveGroups();
    notifyListeners();
    _scheduleNext(dramaId, resolveUrl);
  }

  /// 暂停某集下载
  ///
  /// 注意：[decryptToFile] 不支持取消，若下载已开始则需等当前集完成后才生效。
  void pauseEpisode(EpisodeDownload dl) {
    if (dl.status != DownloadStatus.downloading &&
        dl.status != DownloadStatus.pending) {
      return;
    }
    _pausedKeys.add(dl.key);
    dl.status = DownloadStatus.paused;
    notifyListeners();
  }

  /// 继续某集下载
  void resumeEpisode(EpisodeDownload dl) {
    if (dl.status != DownloadStatus.paused) return;
    _pausedKeys.remove(dl.key);
    dl.status = DownloadStatus.pending;
    notifyListeners();
    final group = _groups[dl.dramaId];
    final resolver =
        _resolvers[dl.key] ??
        (group != null
            ? _buildResolver(group)
            : (Episode ep) async => throw Exception('无法解析下载地址'));
    _scheduleNext(dl.dramaId, resolver);
  }

  /// 暂停整组下载
  void pauseGroup(String dramaId) {
    final group = _groups[dramaId];
    if (group == null) return;
    for (final ep in group.episodes) {
      if (ep.status == DownloadStatus.downloading ||
          ep.status == DownloadStatus.pending) {
        pauseEpisode(ep);
      }
    }
  }

  /// 继续整组下载
  void resumeGroup(String dramaId) {
    final group = _groups[dramaId];
    if (group == null) return;
    for (final ep in group.episodes) {
      if (ep.status == DownloadStatus.paused) {
        _pausedKeys.remove(ep.key);
        ep.status = DownloadStatus.pending;
      }
    }
    notifyListeners();
    final resolver =
        group.episodes
            .map((e) => _resolvers[e.key])
            .firstWhere((r) => r != null, orElse: () => null) ??
        _buildResolver(group);
    _scheduleNext(dramaId, resolver);
  }

  /// 根据 group 信息构建 resolver（用于 resume 时无缓存 resolver 的兜底）
  Future<DownloadResolveResult> Function(Episode) _buildResolver(
    DramaDownloadGroup group,
  ) {
    return (Episode ep) async {
      final videoItems = await apiClient
          .fetchFqVideoModel(ep.url)
          .timeout(const Duration(seconds: 10));
      if (videoItems.isEmpty) throw Exception('未获取到视频信息');

      // 选最高画质
      final selected = videoItems.firstWhere(
        (item) => item.definition == '1080p',
        orElse: () => videoItems.firstWhere(
          (item) => item.definition == '720p',
          orElse: () => videoItems.last,
        ),
      );

      final keyHex = await apiClient
          .fetchDecryptKey(selected.spadeA)
          .timeout(const Duration(seconds: 5));

      return DownloadResolveResult(cdnUrl: selected.url, keyHex: keyHex);
    };
  }

  /// 检查整组是否全部暂停或待下载
  bool isGroupPaused(String dramaId) {
    final group = _groups[dramaId];
    if (group == null) return false;
    final unfinished = group.episodes.where(
      (e) => e.status != DownloadStatus.completed,
    );
    if (unfinished.isEmpty) return false;
    return unfinished.every((e) => e.status == DownloadStatus.paused);
  }

  void retryFailed(
    String dramaId,
    Future<DownloadResolveResult> Function(Episode) resolveUrl,
  ) {
    final group = _groups[dramaId];
    if (group == null) return;
    for (final ep in group.episodes) {
      if (ep.status == DownloadStatus.failed) {
        ep.status = DownloadStatus.pending;
        ep.error = null;
        _resolvers[ep.key] = resolveUrl;
      }
    }
    notifyListeners();
    _scheduleNext(dramaId, resolveUrl);
  }

  void deleteGroup(String dramaId) async {
    final group = _groups.remove(dramaId);
    if (group == null) return;
    for (final ep in group.episodes) {
      _completedKeys.remove(ep.key);
      _pausedKeys.remove(ep.key);
      _resolvers.remove(ep.key);
      if (ep.localPath != null) {
        final f = File(ep.localPath!);
        if (f.existsSync()) f.deleteSync();
      }
    }
    try {
      final dir = await _dramaDir(dramaId);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on Exception catch (_) {}
    await _saveCompletedKeys();
    _scheduleSaveGroups();
    notifyListeners();
  }

  // ── Internal ──────────────────────────────────────────────────

  /// 强制保存当前状态（供 app 进入后台时调用）
  Future<void> saveState() async {
    _saveDebounce?.cancel();
    await _saveGroups();
    await _saveCompletedKeys();
  }

  Future<void> _downloadCover(DramaDownloadGroup group, String url) async {
    try {
      final dir = await _dramaDir(group.dramaId);
      final path = '${dir.path}/cover.jpg';
      await _dio.download(url, path);
      group.localCoverPath = path;
      notifyListeners();
    } on Exception catch (_) {}
  }

  void _scheduleNext(
    String dramaId,
    Future<DownloadResolveResult> Function(Episode) resolveUrl,
  ) {
    final group = _groups[dramaId];
    if (group == null) return;

    final pending = group.episodes
        .where(
          (e) =>
              e.status == DownloadStatus.pending &&
              !_activeKeys.contains(e.key),
        )
        .toList();

    final slots = _concurrency - _activeKeys.length;
    for (var i = 0; i < slots && i < pending.length; i++) {
      _downloadEpisode(pending[i], resolveUrl);
    }
  }

  Future<void> _downloadEpisode(
    EpisodeDownload dl,
    Future<DownloadResolveResult> Function(Episode) resolveUrl,
  ) async {
    if (_pausedKeys.contains(dl.key)) return;
    _activeKeys.add(dl.key);
    dl.status = DownloadStatus.downloading;
    dl.progress = -1.0;
    notifyListeners();

    const maxRetries = 2;
    int attempt = 0;

    while (attempt <= maxRetries) {
      // 在每次尝试前检查暂停状态（decryptToFile 不支持取消，只能在开始前拦截）
      if (_pausedKeys.contains(dl.key)) {
        dl.status = DownloadStatus.paused;
        break;
      }

      try {
        final resolved = await resolveUrl(dl.episode);
        final dir = await _dramaDir(dl.dramaId);
        final path = '${dir.path}/ep_${dl.episode.index}.mp4';

        final now = DateTime.now();
        if (now.difference(_lastNotify).inMilliseconds >= 300) {
          _lastNotify = now;
          notifyListeners();
        }

        final status = await CryptoNativeChannel.instance.decryptToFile(
          resolved.cdnUrl,
          resolved.keyHex,
          path,
        );

        if (status != 0) {
          throw Exception('native decryptToFile 失败: status=$status');
        }

        dl.status = DownloadStatus.completed;
        dl.localPath = path;
        dl.progress = 1.0;
        _completedKeys.add(dl.key);
        await _saveCompletedKeys();
        _scheduleSaveGroups();
        break;
      } on Exception catch (e) {
        attempt++;
        if (attempt > maxRetries) {
          dl.status = DownloadStatus.failed;
          dl.error = e.toString();
        } else {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    }

    _activeKeys.remove(dl.key);
    notifyListeners();
    if (dl.status != DownloadStatus.paused) {
      _scheduleNext(dl.dramaId, resolveUrl);
    }
  }
}
