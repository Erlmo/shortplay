import 'package:flutter/foundation.dart';
import '../models/danmaku.dart';
import 'api_client.dart';

class DanmakuService {
  DanmakuService({required this.apiClient});

  final ApiClient apiClient;

  final List<DanmakuComment> _comments = [];
  String _groupId = '';
  int _durationMs = 0;
  String _cursor = '';
  int _nextStartOffset = 0;
  bool _hasMore = true;
  bool _isLoading = false;

  List<DanmakuComment> get comments => List.unmodifiable(_comments);
  int get commentCount => _comments.length;
  bool get isLoading => _isLoading;
  int get loadedUpToMs => _nextStartOffset;

  void reset() {
    _comments.clear();
    _groupId = '';
    _durationMs = 0;
    _cursor = '';
    _nextStartOffset = 0;
    _hasMore = true;
    _isLoading = false;
  }

  Future<void> loadForEpisode({
    required String groupId,
    required int durationMs,
  }) async {
    if (groupId == _groupId && _comments.isNotEmpty) return;
    reset();
    _groupId = groupId;
    _durationMs = durationMs > 0 ? durationMs : 180000;
    await _loadNextBatch();
  }

  Future<void> ensureLoadedUpTo(int positionMs) async {
    if (_isLoading || _groupId.isEmpty) return;
    // 红果 ON_SEEK_FINISH：拖到还没加载的位置时，直接从该位置所在的 30 秒窗口请求，
    // 而不是从上一个窗口一段段追上去（追的过程中那段时间的弹幕都会错过）。
    if (positionMs > _nextStartOffset + _windowMs) {
      _nextStartOffset = positionMs ~/ _windowMs * _windowMs;
      _cursor = '';
      _hasMore = _nextStartOffset < _durationMs;
    }
    if (!_hasMore) return;
    // 提前 15 秒预取下一段（红果 ON_PROGRESS_UPDATE）
    if (positionMs + 15000 > _nextStartOffset) {
      await _loadNextBatch();
    }
  }

  static const _windowMs = 30000;

  Future<void> _loadNextBatch() async {
    if (_isLoading || !_hasMore) return;
    _isLoading = true;
    try {
      final response = await _fetchWithRetry();
      if (response == null) return;

      final prevOffset = _nextStartOffset;
      _cursor = response.cursor;
      _hasMore = response.hasMore && response.cursor.isNotEmpty;
      _nextStartOffset = response.endOffsetMs;

      if (_nextStartOffset <= prevOffset) {
        _nextStartOffset = prevOffset + _windowMs;
      }
      if (_nextStartOffset >= _durationMs) {
        _hasMore = false;
      }

      final windowMs = _nextStartOffset - prevOffset;
      final batch = response.comments
        ..sort((a, b) => a.offsetMs.compareTo(b.offsetMs));

      // 红果：每条弹幕按它自己的 offset_time（发送时所在的视频时间点，毫秒）出现。
      // 只有接口没给时间点的条目，才在本窗口内均匀铺开兜底。
      final missing = batch.where((c) => c.offsetMs <= 0).toList();
      for (final c in batch) {
        if (c.offsetMs > 0) c.fireAtMs = c.offsetMs;
      }
      if (missing.isNotEmpty && windowMs > 0) {
        final interval = windowMs / missing.length;
        for (int i = 0; i < missing.length; i++) {
          missing[i].fireAtMs = prevOffset + (interval * i).round();
        }
      }

      final known = {for (final c in _comments) c.id};
      _comments.addAll(batch.where((c) => c.id.isEmpty || known.add(c.id)));
      _comments.sort((a, b) => a.fireAtMs.compareTo(b.fireAtMs));

      debugPrint(
        '[DANMAKU] loaded ${batch.length}, '
        'total: ${_comments.length}, '
        'window: ${prevOffset}ms-${_nextStartOffset}ms, '
        'hasMore: $_hasMore',
      );
    } catch (e) {
      debugPrint('[DANMAKU] load error: $e');
    } finally {
      _isLoading = false;
    }
  }

  Future<DanmakuResponse?> _fetchWithRetry({int retries = 2}) async {
    for (int i = 0; i <= retries; i++) {
      try {
        return await apiClient.fetchDanmaku(
          groupId: _groupId,
          duration: _durationMs,
          startOffsetTime: _nextStartOffset > 0 ? _nextStartOffset : null,
          cursor: _cursor.isNotEmpty ? _cursor : null,
        );
      } catch (e) {
        if (i == retries) return null;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }
}
