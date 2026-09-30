import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/episode.dart';
import 'api_client.dart';
import 'crypto_native_channel.dart';

enum DownloadStatus { pending, downloading, paused, completed, failed }

typedef DownloadResolver = Future<DownloadResolveResult> Function(Episode);
typedef DecryptFile = Future<int> Function(String, String, String);

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
    DownloadStatus status = DownloadStatus.pending,
    double progress = 0,
    String? localPath,
    String? error,
    int? fileSize,
  })  : _status = status,
        _progress = progress,
        _localPath = localPath,
        _error = error,
        _fileSize = fileSize;

  final String dramaId;
  final String dramaName;
  final Episode episode;
  DownloadStatus _status;
  double _progress;
  String? _localPath;
  String? _error;
  int? _fileSize;

  DownloadStatus get status => _status;
  double get progress => _progress;
  String? get localPath => _localPath;
  String? get error => _error;
  String get key => '${dramaId}_${episode.index}';

  /// 完成标记不等于文件可用；缺失、空文件或大小变化都需要重新下载。
  bool get isPlayable {
    final path = _localPath;
    if (_status != DownloadStatus.completed || path == null) return false;
    try {
      final size = File(path).lengthSync();
      return size > 0 && (_fileSize == null || size == _fileSize);
    } on FileSystemException {
      return false;
    }
  }
}

class DramaDownloadGroup {
  DramaDownloadGroup({
    required this.dramaId,
    required this.dramaName,
    required List<EpisodeDownload> episodes,
    this.coverUrl,
    this.localCoverPath,
    this.isTheaterResource = false,
  }) : _episodes = List.of(episodes);

  final String dramaId;
  final String dramaName;
  final List<EpisodeDownload> _episodes;
  final String? coverUrl;
  String? localCoverPath;
  final bool isTheaterResource;

  List<EpisodeDownload> get episodes => List.unmodifiable(_episodes);
  int get completedCount => _episodes.where((e) => e.isPlayable).length;
  int get totalCount => _episodes.length;
  int get failedCount => _episodes
      .where((e) =>
          e.status == DownloadStatus.failed ||
          (e.status == DownloadStatus.completed && !e.isPlayable))
      .length;
  bool get isAllCompleted => totalCount > 0 && completedCount == totalCount;
  bool get hasQueuedDownloads => _episodes.any((e) =>
      e.status == DownloadStatus.pending ||
      e.status == DownloadStatus.downloading);
}

/// 全局三并发队列。下载先写独立临时文件，成功校验后原子改名。
/// native 暂不支持取消：暂停/删除立即撤销提交资格，底层返回后清理临时文件。
class DownloadService extends ChangeNotifier {
  DownloadService({
    required this.apiClient,
    Future<Directory> Function()? documentsDirectory,
    Future<SharedPreferences> Function()? preferences,
    DecryptFile? decryptToFile,
    Duration retryDelay = const Duration(seconds: 2),
  })  : _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory,
        _preferences = preferences ?? SharedPreferences.getInstance,
        _decryptToFile =
            decryptToFile ?? CryptoNativeChannel.instance.decryptToFile,
        _retryDelay = retryDelay {
    _initialization = _loadState();
  }

  static const int _concurrency = 3;
  static const String _stateKey = 'download_state_v3';
  static const String _legacyGroupsKey = 'download_groups_v2';
  static const String _legacyCompletedKey = 'download_completed_keys';

  final ApiClient apiClient;
  final Future<Directory> Function() _documentsDirectory;
  final Future<SharedPreferences> Function() _preferences;
  final DecryptFile _decryptToFile;
  final Duration _retryDelay;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 15),
  ));
  final Map<String, DramaDownloadGroup> _groups = {};
  final Map<EpisodeDownload, DownloadResolver> _resolvers = {};
  final Map<EpisodeDownload, _DownloadRun> _active = {};
  final Map<DramaDownloadGroup, CancelToken> _covers = {};
  late final Future<void> _initialization;
  late SharedPreferences _prefs;
  late Directory _base;
  Future<void> _writes = Future<void>.value();
  int _pendingWrites = 0;
  int _runId = 0;
  bool _disposed = false;
  bool _loaded = false;
  String? _initializationError;
  String? _lastError;

  bool get loaded => _loaded;
  String? get lastError => _lastError;
  Map<String, DramaDownloadGroup> get groups => Map.unmodifiable(_groups);

  Future<void> ensureLoaded() async {
    await _initialization;
    if (_initializationError != null) throw ApiException(_initializationError!);
    if (_disposed) throw StateError('缓存服务已关闭');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Directory _directory(String dramaId) =>
      Directory('${_base.path}/downloads/${Uri.encodeComponent(dramaId)}');

  String _episodePath(String dramaId, int index) =>
      '${_directory(dramaId).path}/ep_$index.mp4';

  Future<void> _loadState() async {
    try {
      _prefs = await _preferences();
      _base = await _documentsDirectory();
      final saved = _prefs.getString(_stateKey);
      final legacy = saved == null;
      final List<Object?> records;
      final completed =
          _prefs.getStringList(_legacyCompletedKey)?.toSet() ?? {};
      if (legacy) {
        records = _prefs.getStringList(_legacyGroupsKey) ?? [];
      } else {
        final state = jsonDecode(saved) as Map<String, dynamic>;
        if (state['version'] != 3) throw const FormatException('未知缓存版本');
        records = state['groups'] as List;
      }
      bool damaged = false;
      for (final record in records) {
        try {
          final map = (legacy ? jsonDecode(record as String) : record)
              as Map<String, dynamic>;
          final id = map['dramaId'] as String;
          final name = map['dramaName'] as String;
          if (id.isEmpty || id == '.' || id == '..') {
            throw const FormatException('无效剧集标识');
          }
          final episodes = <EpisodeDownload>[];
          final indexes = <int>{};
          for (final value in map['episodes'] as List) {
            try {
              final item = value as Map<String, dynamic>;
              final ep = Episode.fromJson(item);
              if (ep.index < 0 ||
                  ep.url.trim().isEmpty ||
                  !indexes.add(ep.index)) {
                throw const FormatException('无效缓存集数');
              }
              final markedCompleted = legacy
                  ? completed.contains('${id}_${ep.index}')
                  : item['status'] == DownloadStatus.completed.name;
              final download = EpisodeDownload(
                dramaId: id,
                dramaName: name,
                episode: ep,
                status: markedCompleted
                    ? DownloadStatus.completed
                    : item['status'] == DownloadStatus.failed.name
                        ? DownloadStatus.failed
                        : DownloadStatus.paused,
                localPath: markedCompleted ? _episodePath(id, ep.index) : null,
                fileSize: item['fileSize'] as int?,
                error: item['error'] as String?,
              );
              if (markedCompleted && !download.isPlayable) {
                _reset(download, DownloadStatus.failed,
                    error: '本地文件已丢失或损坏，请重试');
              } else if (download.isPlayable) {
                download._progress = 1;
                download._fileSize = File(download.localPath!).lengthSync();
              }
              episodes.add(download);
            } catch (error) {
              damaged = true;
              debugPrint('跳过损坏的缓存记录: $error');
            }
          }
          if (episodes.isEmpty) continue;
          final cover = '${_directory(id).path}/cover.jpg';
          _groups[id] = DramaDownloadGroup(
            dramaId: id,
            dramaName: name,
            episodes: episodes,
            coverUrl: map['coverUrl'] as String?,
            localCoverPath: File(cover).existsSync() ? cover : null,
            isTheaterResource: map['isTheaterResource'] as bool? ?? false,
          );
        } catch (error) {
          damaged = true;
          debugPrint('跳过损坏的缓存分组: $error');
        }
      }
      // 启动时没有运行中的 native 任务，可安全清理上次中断的临时文件。
      final root = Directory('${_base.path}/downloads');
      if (root.existsSync()) {
        for (final file in root.listSync(recursive: true, followLinks: false)) {
          if (file is File && file.path.endsWith('.part')) {
            _removeFile(file.path);
          }
        }
      }
      if (!_disposed) await _persist();
      if (damaged) _lastError = '部分缓存记录损坏，已保留可恢复的剧集；缺失剧集请重新添加';
    } catch (error) {
      _initializationError = '读取缓存失败，请重启后重试';
      _lastError = _initializationError;
      debugPrint('读取缓存失败: $error');
    } finally {
      _loaded = true;
      _notify();
    }
  }

  /// 单个快照包含任务和完成状态，串行写入以防旧快照覆盖新状态。
  Future<void> _persist() {
    final snapshot = jsonEncode({
      'version': 3,
      'groups': _groups.values
          .map((g) => {
                'dramaId': g.dramaId,
                'dramaName': g.dramaName,
                'coverUrl': g.coverUrl,
                'isTheaterResource': g.isTheaterResource,
                'episodes': g.episodes
                    .map((d) => {
                          'index': d.episode.index,
                          'name': d.episode.name,
                          'size': d.episode.size,
                          'url': d.episode.url,
                          'status': d.status.name,
                          'fileSize': d._fileSize,
                          'error': d.error,
                        })
                    .toList(),
              })
          .toList(),
    });
    _pendingWrites++;
    final operation = _writes.then((_) async {
      if (!await _prefs.setString(_stateKey, snapshot)) {
        throw const FileSystemException('保存缓存状态失败');
      }
      _lastError = null;
    }).whenComplete(() => _pendingWrites--);
    // 链尾吸收异常保证后续保存仍可重试，当前调用方仍收到原异常。
    _writes = operation.catchError((Object error) {
      _lastError = '缓存状态保存失败，请检查存储空间后重试';
      debugPrint('保存缓存失败: $error');
      _notify();
    });
    return operation;
  }

  Future<void> saveState() async {
    await ensureLoaded();
    await _persist();
    _schedule();
  }

  Future<void> _saveAndSchedule() async {
    try {
      await _persist();
      _schedule();
    } catch (_) {
      // _persist 已记录并展示保存失败，暂停调度直至保存成功。
    }
  }

  /// 返回实际新加入或重新排队的集数，重复点击不会创建重复任务。
  Future<int> addDownloads({
    required String dramaId,
    required String dramaName,
    required List<Episode> episodes,
    DownloadResolver? resolveUrl,
    String? coverUrl,
    bool isTheaterResource = false,
  }) async {
    await ensureLoaded();
    if (dramaId.isEmpty || dramaId == '.' || dramaId == '..') {
      throw ApiException('剧集信息无效');
    }
    if (episodes.isEmpty) throw ApiException('暂无可下载的集数');
    final unique = <int, Episode>{};
    for (final ep in episodes) {
      if (ep.index <= 0 || ep.url.trim().isEmpty) {
        throw ApiException('剧集编号或视频标识无效，请刷新后重试');
      }
      if (unique.containsKey(ep.index) && unique[ep.index]!.url != ep.url) {
        throw ApiException('存在重复集号，请刷新剧集列表后重试');
      }
      unique[ep.index] = ep;
    }
    final existing = _groups[dramaId];
    for (final ep in existing?.episodes ?? <EpisodeDownload>[]) {
      if (unique.containsKey(ep.episode.index) &&
          unique[ep.episode.index]!.url != ep.episode.url) {
        throw ApiException('剧集列表已变化，请删除旧缓存后重新下载');
      }
    }
    final group = existing ??
        DramaDownloadGroup(
          dramaId: dramaId,
          dramaName: dramaName,
          episodes: [],
          coverUrl: coverUrl,
          isTheaterResource: isTheaterResource,
        );
    int queued = 0;
    for (final ep in unique.values) {
      var dl =
          group._episodes.where((d) => d.episode.index == ep.index).firstOrNull;
      if (dl == null) {
        dl = EpisodeDownload(
            dramaId: dramaId, dramaName: dramaName, episode: ep);
        group._episodes.add(dl);
        queued++;
      } else if (!dl.isPlayable &&
          dl.status != DownloadStatus.pending &&
          dl.status != DownloadStatus.downloading) {
        _reset(dl, DownloadStatus.pending);
        queued++;
      }
      if (resolveUrl != null) _resolvers[dl] = resolveUrl;
    }
    group._episodes.sort((a, b) => a.episode.index.compareTo(b.episode.index));
    _groups[dramaId] = group;
    _notify();
    await _persist();
    _schedule();
    if (identical(_groups[dramaId], group) &&
        group.localCoverPath == null &&
        coverUrl != null &&
        coverUrl.isNotEmpty &&
        !_covers.containsKey(group)) {
      // 封面独立下载，失败不影响视频任务。
      unawaited(_downloadCover(group, coverUrl));
    }
    return queued;
  }

  bool _contains(EpisodeDownload dl) =>
      !_disposed && (_groups[dl.dramaId]?._episodes.contains(dl) ?? false);

  void _reset(EpisodeDownload dl, DownloadStatus status, {String? error}) {
    dl._status = status;
    dl._progress = 0;
    dl._localPath = null;
    dl._fileSize = null;
    dl._error = error;
  }

  void pauseEpisode(EpisodeDownload dl) {
    if (!_contains(dl) ||
        (dl.status != DownloadStatus.pending &&
            dl.status != DownloadStatus.downloading)) {
      return;
    }
    _active[dl]?.cancelled = true;
    _reset(dl, DownloadStatus.paused);
    _notify();
    unawaited(_saveAndSchedule());
  }

  void resumeEpisode(EpisodeDownload dl) {
    if (!_contains(dl) ||
        dl.isPlayable ||
        dl.status == DownloadStatus.downloading) {
      return;
    }
    _reset(dl, DownloadStatus.pending);
    _notify();
    unawaited(_saveAndSchedule());
  }

  void pauseGroup(String dramaId) {
    final group = _groups[dramaId];
    if (group == null || _disposed) return;
    for (final dl in group.episodes) {
      if (dl.status == DownloadStatus.pending ||
          dl.status == DownloadStatus.downloading) {
        _active[dl]?.cancelled = true;
        _reset(dl, DownloadStatus.paused);
      }
    }
    _notify();
    unawaited(_saveAndSchedule());
  }

  void resumeGroup(String dramaId) {
    final group = _groups[dramaId];
    if (group == null || _disposed) return;
    for (final dl in group.episodes) {
      if (!dl.isPlayable && dl.status != DownloadStatus.downloading) {
        _reset(dl, DownloadStatus.pending);
      }
    }
    _notify();
    unawaited(_saveAndSchedule());
  }

  bool isGroupPaused(String dramaId) {
    final group = _groups[dramaId];
    return group != null && !group.isAllCompleted && !group.hasQueuedDownloads;
  }

  void retryFailed(String dramaId, DownloadResolver resolveUrl) {
    final group = _groups[dramaId];
    if (group == null || _disposed) return;
    for (final dl in group.episodes) {
      if (dl.status == DownloadStatus.failed) {
        _resolvers[dl] = resolveUrl;
        _reset(dl, DownloadStatus.pending);
      }
    }
    _notify();
    unawaited(_saveAndSchedule());
  }

  Future<void> deleteGroup(String dramaId) async {
    await ensureLoaded();
    final group = _groups[dramaId];
    if (group == null) return;
    // 同步删除目录和移除模型，避免 await 期间重新加入的任务被误删。
    final dir = _directory(dramaId);
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      throw ApiException('删除缓存文件失败，请稍后重试');
    }
    _groups.remove(dramaId);
    _covers.remove(group)?.cancel();
    for (final dl in group.episodes) {
      _active[dl]?.cancelled = true;
      _resolvers.remove(dl);
    }
    _notify();
    await _persist();
    _schedule();
  }

  /// 前台恢复/手动刷新时同步磁盘状态，提供明确的重新下载入口。
  Future<void> refreshFiles() async {
    await ensureLoaded();
    for (final group in _groups.values) {
      for (final dl in group.episodes) {
        if (dl.status == DownloadStatus.completed && !dl.isPlayable) {
          _reset(dl, DownloadStatus.failed, error: '本地文件已丢失或损坏，请重试');
        }
      }
    }
    _notify();
    await _persist();
    _schedule();
  }

  Future<DownloadResolveResult> _resolve(Episode ep) async {
    final items = await apiClient
        .fetchFqVideoModel(ep.url)
        .timeout(const Duration(seconds: 10));
    if (items.isEmpty) throw ApiException('未获取到视频信息');
    final selected = items.firstWhere((item) => item.definition == '1080p',
        orElse: () => items.firstWhere((item) => item.definition == '720p',
            orElse: () => items.last));
    final key = await apiClient
        .fetchDecryptKey(selected.spadeA)
        .timeout(const Duration(seconds: 5));
    return DownloadResolveResult(cdnUrl: selected.url, keyHex: key);
  }

  void _schedule() {
    if (_disposed || !_loaded || _pendingWrites > 0 || _lastError != null) {
      return;
    }
    for (final group in _groups.values) {
      for (final dl in group.episodes) {
        if (_active.length >= _concurrency) {
          _notify();
          return;
        }
        if (dl.status != DownloadStatus.pending || _active.containsKey(dl)) {
          continue;
        }
        final run = _DownloadRun(
          '${_episodePath(dl.dramaId, dl.episode.index)}.${DateTime.now().microsecondsSinceEpoch}.${_runId++}.part',
        );
        _active[dl] = run;
        dl._status = DownloadStatus.downloading;
        dl._progress = -1;
        // 任务自身处理错误并在 finally 中释放全局并发槽。
        unawaited(_downloadEpisode(dl, run, _resolvers[dl] ?? _resolve));
      }
    }
    _notify();
  }

  bool _canCommit(EpisodeDownload dl, _DownloadRun run) =>
      _contains(dl) && !run.cancelled && identical(_active[dl], run);

  Future<void> _downloadEpisode(
      EpisodeDownload dl, _DownloadRun run, DownloadResolver resolver) async {
    try {
      for (int attempt = 0; attempt < 3; attempt++) {
        if (!_canCommit(dl, run)) return;
        try {
          final result = await resolver(dl.episode);
          if (!_canCommit(dl, run)) return;
          if (result.cdnUrl.isEmpty || result.keyHex.isEmpty) {
            throw ApiException('视频地址或解密密钥为空');
          }
          _directory(dl.dramaId).createSync(recursive: true);
          final status =
              await _decryptToFile(result.cdnUrl, result.keyHex, run.path);
          if (!_canCommit(dl, run)) return;
          final temporary = File(run.path);
          if (status != 0) throw ApiException('视频下载失败（状态码 $status）');
          if (!temporary.existsSync() || temporary.lengthSync() == 0) {
            throw ApiException('下载未生成有效文件，请重试');
          }
          final size = temporary.lengthSync();
          final path = _episodePath(dl.dramaId, dl.episode.index);
          temporary.renameSync(path);
          dl._localPath = path;
          dl._fileSize = size;
          dl._status = DownloadStatus.completed;
          dl._progress = 1;
          dl._error = null;
          break;
        } catch (error) {
          _removeFile(run.path);
          if (!_canCommit(dl, run)) return;
          if (attempt == 2) {
            _reset(dl, DownloadStatus.failed,
                error: error is ApiException
                    ? error.message
                    : '缓存失败，请检查网络或存储空间后重试');
            debugPrint('缓存第${dl.episode.index}集失败: $error');
          } else {
            await Future<void>.delayed(_retryDelay * (attempt + 1));
          }
        }
      }
    } finally {
      _removeFile(run.path);
      _active.remove(dl);
      if (!_disposed) {
        _notify();
        await _saveAndSchedule();
      }
    }
  }

  Future<void> _downloadCover(DramaDownloadGroup group, String url) async {
    final token = CancelToken();
    _covers[group] = token;
    final path =
        '${_directory(group.dramaId).path}/cover.${DateTime.now().microsecondsSinceEpoch}.part';
    try {
      _directory(group.dramaId).createSync(recursive: true);
      await _dio.download(url, path, cancelToken: token);
      if (_disposed || !identical(_groups[group.dramaId], group)) return;
      final file = File(path);
      if (file.lengthSync() == 0) return;
      final target = '${_directory(group.dramaId).path}/cover.jpg';
      file.renameSync(target);
      group.localCoverPath = target;
      _notify();
    } catch (error) {
      if (!token.isCancelled) debugPrint('缓存封面下载失败: $error');
    } finally {
      _removeFile(path);
      _covers.remove(group);
    }
  }

  void _removeFile(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException catch (error) {
      debugPrint('清理临时文件失败: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final run in _active.values) {
      run.cancelled = true;
    }
    _dio.close(force: true);
    super.dispose();
  }
}

class _DownloadRun {
  _DownloadRun(this.path);
  final String path;
  bool cancelled = false;
}
