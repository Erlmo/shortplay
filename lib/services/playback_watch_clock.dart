/// 根据实际播放状态累计前台可见的观看时间。
/// 时间来自单调时钟，与播放进度、拖动位置和倍速无关。
class PlaybackWatchClock {
  PlaybackWatchClock({Duration Function()? elapsedTime})
      : _elapsedTime = elapsedTime ?? _monotonicClock() {
    _lastSample = _elapsedTime();
  }

  final Duration Function() _elapsedTime;
  late Duration _lastSample;
  Duration _watched = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _visible = false;
  bool _foreground = true;
  bool _seeking = false;

  bool get _running =>
      _playing && _visible && _foreground && !_buffering && !_seeking;

  Duration get watched {
    _sample();
    return _watched;
  }

  void update({
    bool? playing,
    bool? buffering,
    bool? visible,
    bool? foreground,
    bool? seeking,
  }) {
    _sample();
    _playing = playing ?? _playing;
    _buffering = buffering ?? _buffering;
    _visible = visible ?? _visible;
    _foreground = foreground ?? _foreground;
    _seeking = seeking ?? _seeking;
  }

  void _sample() {
    final now = _elapsedTime();
    final delta = now - _lastSample;
    if (_running && delta > Duration.zero) _watched += delta;
    _lastSample = now;
  }

  static Duration Function() _monotonicClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}
