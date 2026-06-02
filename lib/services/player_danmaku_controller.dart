import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/danmaku.dart';
import '../models/episode.dart';
import 'api_client.dart';
import 'danmaku_service.dart';

class PlayerDanmakuController extends ChangeNotifier {
  PlayerDanmakuController({required ApiClient apiClient})
      : _service = DanmakuService(apiClient: apiClient);

  final DanmakuService _service;

  bool _disposed = false;

  bool enabled = true;
  List<DanmakuComment> comments = const [];

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
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
    required int durationMs,
  }) async {
    enabled = !enabled;
    _safeNotify();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('danmaku_enabled', enabled);

    if (!enabled || comments.isNotEmpty) return;
    if (currentEpisode == null) return;
    await loadForEpisode(
      episode: currentEpisode,
      durationMs: durationMs,
      isOfflinePlayback: isOfflinePlayback,
    );
  }

  Future<void> loadForEpisode({
    required Episode episode,
    required int durationMs,
    required bool isOfflinePlayback,
  }) async {
    if (isOfflinePlayback) return;
    final groupId = episode.url.trim();
    if (groupId.isEmpty) return;
    final dur = durationMs > 0 ? durationMs : 180000;
    await _service.loadForEpisode(groupId: groupId, durationMs: dur);
    if (_disposed) return;
    comments = _service.comments;
    _safeNotify();
  }

  Future<void> ensureLoadedUpTo({
    required int positionMs,
    required bool isTheaterResource,
    required bool isOfflinePlayback,
  }) async {
    if (!isTheaterResource || isOfflinePlayback) return;
    await _service.ensureLoadedUpTo(positionMs);
    if (_disposed) return;
    if (_service.commentCount == comments.length) return;
    comments = _service.comments;
    _safeNotify();
  }

  void clearComments() {
    if (comments.isEmpty) return;
    comments = const [];
    _safeNotify();
  }
}
