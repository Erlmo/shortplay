import 'playback_report_queue.dart';
import 'playback_watch_clock.dart';

/// 只把当前播放器的有效媒体进度增量累计到整部剧，seek 跃迁不会增加时长。
class PlaybackReportSession {
  PlaybackReportSession({
    required this.bookId,
    required this.itemId,
    required this.vidIndex,
    required PlaybackReportQueue queue,
    required int initialPositionMs,
    Duration Function()? elapsedTime,
    int Function()? timestampMs,
  })  : _queue = queue,
        _clock = PlaybackWatchClock(elapsedTime: elapsedTime),
        _timestampMs = timestampMs ?? _nowMs,
        _positionMs = initialPositionMs,
        _lastPositionMs = initialPositionMs;

  final String bookId;
  final String itemId;
  final int vidIndex;
  final PlaybackReportQueue _queue;
  final PlaybackWatchClock _clock;
  final int Function() _timestampMs;
  int _positionMs;
  int _lastPositionMs;
  int _lastWatchedMs = 0;
  int _uncommittedMs = 0;
  int? _seekTarget;
  int? _seekSamplePosition;
  double _rate = 1;
  bool _active = false;
  bool _dirty = false;
  bool _closed = false;
  bool _hasWatched = false;

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  void update({
    required bool playing,
    required bool buffering,
    required bool foreground,
    required bool visible,
    required bool seeking,
    required double rate,
  }) {
    _clock.update(
      playing: playing,
      buffering: buffering,
      foreground: foreground,
      visible: visible,
      seeking: seeking,
    );
    _active = playing && !buffering && foreground && visible && !seeking;
    _rate = rate;
    if (!_active) _lastWatchedMs = _clock.watched.inMilliseconds;
  }

  void position(int positionMs) {
    if (_closed || positionMs < 0) return;
    final watchedMs = _clock.watched.inMilliseconds;
    final wallDelta = watchedMs - _lastWatchedMs;
    final mediaDelta = positionMs - _lastPositionMs;
    final target = _seekTarget;
    if (target != null) {
      // 等待原生确认新位置；旧的异步进度事件不能越过 seek 边界。
      final previousSeekSample = _seekSamplePosition;
      final reachedTarget = (positionMs - target).abs() <= 1000;
      // 慢回调可能已越过目标一秒，连续自然前进后以当前位置重建基线。
      final resumedProgress = previousSeekSample != null &&
          positionMs >= target &&
          positionMs > previousSeekSample &&
          positionMs - previousSeekSample <= wallDelta * _rate + 1000;
      if (reachedTarget || resumedProgress) _seekTarget = null;
      _seekSamplePosition = positionMs;
    } else if (_active &&
        wallDelta > 0 &&
        mediaDelta > 0 &&
        mediaDelta <= wallDelta * _rate + 1000) {
      _uncommittedMs += mediaDelta;
      _dirty = true;
      _hasWatched = true;
    }
    if (_hasWatched && _positionMs != positionMs) _dirty = true;
    _positionMs = positionMs;
    _lastPositionMs = positionMs;
    _lastWatchedMs = watchedMs;
  }

  void seek(int targetMs) {
    if (_closed) return;
    if (_hasWatched && _positionMs != targetMs) _dirty = true;
    _positionMs = targetMs;
    _lastPositionMs = targetMs;
    _lastWatchedMs = _clock.watched.inMilliseconds;
    _seekTarget = targetMs;
    _seekSamplePosition = null;
  }

  Future<void> checkpoint({bool close = false}) async {
    if (_closed) return;
    if (close) _closed = true;
    if (!_dirty) return;
    final delta = _uncommittedMs;
    _uncommittedMs = 0;
    _dirty = false;
    await _queue.checkpoint(
      bookId: bookId,
      itemId: itemId,
      positionMs: _positionMs,
      playedDeltaMs: delta,
      vidIndex: vidIndex,
      timestampMs: _timestampMs(),
    );
  }
}
