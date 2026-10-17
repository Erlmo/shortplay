import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/danmaku.dart';
import '../models/episode.dart';
import 'api_client.dart';
import 'danmaku_service.dart';

class PlayerDanmakuController extends ChangeNotifier {
  PlayerDanmakuController({required ApiClient apiClient}) {
    _service = DanmakuService(
      apiClient: apiClient,
      onCommentsChanged: _onCommentsChanged,
    );
  }

  late final DanmakuService _service;
  bool _disposed = false;
  bool enabled = true;
  List<DanmakuComment> comments = const [];

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _onCommentsChanged(List<DanmakuComment> snapshot) {
    if (_disposed) return;
    comments = snapshot;
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _service.dispose();
    super.dispose();
  }

  void setEnabled(bool value) {
    if (enabled == value) return;
    enabled = value;
    _safeNotify();
  }

  Future<void> toggle({
    required bool isOfflinePlayback,
    required Episode? currentEpisode,
    required String bookId,
    required int durationMs,
    int positionMs = 0,
  }) async {
    enabled = !enabled;
    _safeNotify();
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    await prefs.setBool('danmaku_enabled', enabled);
    if (!enabled || _disposed || currentEpisode == null) return;
    await loadForEpisode(
      episode: currentEpisode,
      bookId: bookId,
      durationMs: durationMs,
      positionMs: positionMs,
      isOfflinePlayback: isOfflinePlayback,
    );
  }

  Future<void> loadForEpisode({
    required Episode episode,
    required String bookId,
    required int durationMs,
    required bool isOfflinePlayback,
    int positionMs = 0,
  }) async {
    if (_disposed || isOfflinePlayback || !enabled) return;
    final groupId = episode.url.trim();
    if (groupId.isEmpty) return;
    await _service.loadForEpisode(
        groupId: groupId,
        bookId: bookId,
        durationMs: durationMs,
        positionMs: positionMs);
  }

  Future<void> ensureLoadedUpTo({
    required int positionMs,
    required bool isTheaterResource,
    required bool isOfflinePlayback,
    int? durationMs,
    bool seek = false,
  }) async {
    if (_disposed || !enabled || !isTheaterResource || isOfflinePlayback) {
      return;
    }
    await _service.ensureLoadedUpTo(positionMs,
        seek: seek, durationMs: durationMs);
  }

  void clearComments() {
    _service.reset();
    if (comments.isEmpty) return;
    comments = const [];
    _safeNotify();
  }
}
