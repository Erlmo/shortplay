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
    if (!_hasMore || _isLoading || _groupId.isEmpty) return;
    if (positionMs + 15000 > _nextStartOffset) {
      await _loadNextBatch();
    }
  }

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
        _nextStartOffset = prevOffset + 30000;
      }
      if (_nextStartOffset >= _durationMs) {
        _hasMore = false;
      }

      final windowMs = _nextStartOffset - prevOffset;
      final batch = response.comments
        ..sort((a, b) => a.offsetMs.compareTo(b.offsetMs));

      if (batch.isNotEmpty && windowMs > 0) {
        final interval = windowMs / batch.length;
        for (int i = 0; i < batch.length; i++) {
          batch[i].fireAtMs = prevOffset + (interval * i).round();
        }
      }

      _comments.addAll(batch);

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
