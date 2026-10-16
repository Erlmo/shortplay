import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/danmaku.dart';
import 'api_client.dart';

class _DanmakuWindow {
  const _DanmakuWindow(
      this.startMs, this.endMs, this.nextQueryMs, this.cursor, this.hasMore);

  final int startMs;
  final int endMs;
  final int nextQueryMs;
  final String cursor;
  final bool hasMore;

  bool contains(int positionMs) => startMs <= positionMs && positionMs < endMs;
}

class _DanmakuRequest {
  const _DanmakuRequest(this.startMs, this.cursor);
  final int startMs;
  final String cursor;
}

/// 对应 APK DanmakuRequestHelper 的区间缓存、服务端边界预取与精确 seek。
/// 网络取消/会话代数是 Flutter 侧适配，防止换集时旧请求污染当前时间轴。
class DanmakuService {
  DanmakuService({required this.apiClient});

  final ApiClient apiClient;
  final List<DanmakuComment> _comments = [];
  final List<_DanmakuWindow> _windows = [];
  String _groupId = '';
  String _bookId = '';
  int _durationMs = 0;
  int _positionMs = 0;
  int _generation = 0;
  bool _hasMore = true;
  int? _pendingSeekMs;
  bool _disposed = false;
  Future<void>? _active;
  CancelToken? _cancelToken;
  int _attemptsRemaining = 3;
  Object? lastError;

  // 宿主 vq6.f.K(): getInt("pre_load_sec", 3)，采用其内置默认。
  static const prefetchLeadMs = 3000;

  List<DanmakuComment> get comments => List.unmodifiable(_comments);
  int get commentCount => _comments.length;
  bool get isLoading => _active != null;
  int get loadedUpToMs =>
      _windows.fold(0, (end, w) => w.endMs > end ? w.endMs : end);

  void reset() {
    _generation++;
    _cancelToken?.cancel('episode changed');
    _cancelToken = null;
    _active = null;
    _comments.clear();
    _windows.clear();
    _groupId = '';
    _bookId = '';
    _durationMs = 0;
    _positionMs = 0;
    _hasMore = true;
    _pendingSeekMs = null;
    _attemptsRemaining = 3;
    lastError = null;
  }

  void dispose() {
    _disposed = true;
    reset();
  }

  Future<void> loadForEpisode({
    required String groupId,
    required String bookId,
    required int durationMs,
    int positionMs = 0,
  }) {
    if (_disposed) return Future.value();
    if (groupId != _groupId || bookId != _bookId) {
      reset();
      _groupId = groupId;
      _bookId = bookId;
    }
    _durationMs = durationMs > 0 ? durationMs : 0;
    return ensureLoadedUpTo(positionMs, seek: true);
  }

  Future<void> ensureLoadedUpTo(int positionMs,
      {bool seek = false, int? durationMs}) {
    if (_disposed || _groupId.isEmpty || _bookId.isEmpty) return Future.value();
    _positionMs = positionMs < 0 ? 0 : positionMs;
    if (durationMs != null && durationMs > 0) _durationMs = durationMs;
    if (seek) {
      _pendingSeekMs = _positionMs;
    }
    final active = _active;
    if (active != null) return active;
    final seekPosition = _pendingSeekMs;
    _pendingSeekMs = null;
    if (seekPosition != null) _positionMs = seekPosition;
    final request = _requestForPosition(seekPosition != null);
    if (request == null) return Future.value();
    final generation = _generation;
    final future = _run(request, generation);
    _active = future;
    return future.whenComplete(() {
      if (identical(_active, future)) _active = null;
    });
  }

  _DanmakuWindow? _windowAt(int positionMs) {
    for (final window in _windows.reversed) {
      if (window.contains(positionMs)) return window;
    }
    return null;
  }

  _DanmakuRequest? _requestForPosition(bool seek) {
    if (_durationMs > 0 && _positionMs >= _durationMs) return null;
    if (!seek && _attemptsRemaining <= 0) return null;
    final cached = _windowAt(_positionMs);
    if (cached != null) {
      if (!cached.hasMore ||
          _positionMs < cached.nextQueryMs - prefetchLeadMs ||
          _positionMs >= cached.nextQueryMs ||
          _windowAt(cached.nextQueryMs) != null) {
        return null;
      }
      return _DanmakuRequest(cached.nextQueryMs, cached.cursor);
    }
    if (seek) _hasMore = true;
    if (!_hasMore) return null;
    // 无缓存的实际播放位置直接请求，不制造固定30秒分片。
    if (!seek) {
      for (final window in _windows.reversed) {
        if (window.endMs == _positionMs && window.hasMore) {
          return _DanmakuRequest(_positionMs, window.cursor);
        }
      }
    }
    return _DanmakuRequest(_positionMs, '');
  }

  Future<void> _run(_DanmakuRequest initial, int generation) async {
    var request = initial;
    try {
      while (generation == _generation && !_disposed) {
        final cancel = CancelToken();
        _cancelToken = cancel;
        DanmakuResponse response;
        try {
          response = await apiClient.fetchDanmaku(
            groupId: _groupId,
            bookId: _bookId,
            duration: _durationMs,
            startOffsetTime: request.startMs,
            cursor: request.cursor.isEmpty ? null : request.cursor,
            cancelToken: cancel,
          );
        } catch (error) {
          if (generation != _generation ||
              _disposed ||
              (error is DioException && CancelToken.isCancel(error))) {
            return;
          }
          lastError = error;
          _attemptsRemaining--;
          debugPrint('[DANMAKU] load failed: $error');
          final seekPosition = _pendingSeekMs;
          _pendingSeekMs = null;
          if (seekPosition != null) {
            _positionMs = seekPosition;
            final next = _requestForPosition(true);
            if (next == null) return;
            request = next;
          } else if (_attemptsRemaining <= 0) {
            return;
          }
          // APK 默认旧分支：预算3次，失败队首重试，不添加猜测的定时退避。
          continue;
        }
        if (generation != _generation || _disposed) return;
        lastError = null;
        _attemptsRemaining = 3;
        _hasMore = response.hasMore;
        final end = response.endOffsetMs;
        final cachedStart = response.cachedStartOffsetMs;
        final cachedEnd = response.cachedEndOffsetMs;
        final hasCursorRange = cachedStart != null &&
            cachedEnd != null &&
            cachedStart >= 0 &&
            cachedStart <= request.startMs &&
            cachedEnd > request.startMs;
        final start = hasCursorRange ? cachedStart : request.startMs;
        final cacheEnd = hasCursorRange ? cachedEnd : end;
        if (cacheEnd > start) {
          _windows.add(_DanmakuWindow(
              start, cacheEnd, end, response.cursor, response.hasMore));
        }
        final known = {for (final c in _comments) c.id};
        for (final comment in response.comments) {
          if (comment.content.isEmpty) continue;
          if (comment.id.isNotEmpty && !known.add(comment.id)) continue;
          // 0毫秒是合法时间，不将一批开头弹幕人为均匀摊开。
          comment.fireAtMs = comment.offsetMs;
          _comments.add(comment);
        }
        final order = <DanmakuComment, int>{
          for (var i = 0; i < _comments.length; i++) _comments[i]: i,
        };
        _comments.sort((a, b) {
          final time = a.fireAtMs.compareTo(b.fireAtMs);
          return time != 0 ? time : order[a]!.compareTo(order[b]!);
        });
        debugPrint('[DANMAKU] loaded ${response.comments.length}, '
            'total: ${_comments.length}, interval: ${request.startMs}-$end');
        final seekPosition = _pendingSeekMs;
        _pendingSeekMs = null;
        final seek = seekPosition != null;
        if (seekPosition != null) _positionMs = seekPosition;
        // 服务端未给出可前进边界时不自造窗口或无限循环。
        if (end <= request.startMs && !seek) return;
        final next = _requestForPosition(seek);
        if (next == null ||
            (next.startMs == request.startMs &&
                next.cursor == request.cursor)) {
          return;
        }
        request = next;
      }
    } finally {
      if (generation == _generation) {
        _active = null;
        _cancelToken = null;
      }
    }
  }
}
