import 'dart:async';

/// The Java strategy checks cache every 300ms, independently of media progress.
/// This monitor never plays, seeks, recreates an engine, or counts wall-clock
/// delay as cached media. Its lifetime is bound to the host's playback intent.
class PlaybackBufferMonitor {
  PlaybackBufferMonitor({
    required this.read,
    required this.onSample,
    this.onError,
    this.interval = const Duration(milliseconds: 300),
  });
  final Future<void> Function() read;
  final void Function() onSample;
  final void Function(Object, StackTrace)? onError;
  final Duration interval;
  Timer? _timer;
  bool _reading = false;
  int _generation = 0;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    final generation = ++_generation;
    _timer = Timer.periodic(interval, (_) => unawaited(_sample(generation)));
    unawaited(_sample(generation));
  }

  void stop() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _sample(int generation) async {
    if (_reading || _timer == null || generation != _generation) return;
    _reading = true;
    try {
      await read();
      if (_timer != null && generation == _generation) onSample();
    } catch (error, stack) {
      if (_timer != null && generation == _generation) {
        onError?.call(error, stack);
      }
    } finally {
      _reading = false;
    }
  }
}

/// Cache safety and actual playback intent are separate from isPlaying: a
/// stalled player can be waiting for data while its intent remains "play".
class PlaybackBufferGate {
  PlaybackBufferGate({
    this.startBuffer = const Duration(seconds: 14),
    this.stopBuffer = const Duration(seconds: 5),
    this.unknownBufferDelay = const Duration(seconds: 3),
    this.endTolerance = const Duration(seconds: 1),
  });
  final Duration startBuffer;
  final Duration stopBuffer;
  final Duration unknownBufferDelay;
  final Duration endTolerance;
  bool enabled = false;
  bool networkSafe = false;
  Duration _baseline = Duration.zero;
  Duration _lastPlayed = Duration.zero;

  static bool cacheReachesEnd({
    required Duration position,
    required Duration duration,
    required Duration? bufferedAhead,
    Duration tolerance = const Duration(seconds: 1),
  }) =>
      duration > Duration.zero &&
      position >= Duration.zero &&
      bufferedAhead != null &&
      bufferedAhead >= Duration.zero &&
      position + bufferedAhead + tolerance >= duration;

  void reset() {
    enabled = false;
    networkSafe = false;
    _baseline = Duration.zero;
    _lastPlayed = Duration.zero;
  }

  void update({
    required bool firstFrame,
    required bool buffering,
    required bool active,
    required Duration played,
    Duration? bufferedAhead,
    bool fullyBuffered = false,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
  }) {
    if (played < _lastPlayed) {
      // A backwards seek invalidates the unknown-backend progress baseline.
      _baseline = played;
      networkSafe = false;
    }
    _lastPlayed = played;
    enabled = firstFrame && active && !buffering;
    if (!enabled) {
      networkSafe = false;
      _baseline = played;
    } else if (fullyBuffered ||
        cacheReachesEnd(
            position: position,
            duration: duration,
            bufferedAhead: bufferedAhead,
            tolerance: endTolerance)) {
      networkSafe = true;
    } else if (bufferedAhead != null) {
      if (bufferedAhead < stopBuffer) networkSafe = false;
      if (bufferedAhead > startBuffer) networkSafe = true;
    } else {
      // Host fallback only; TT's Java code uses measured audio/video buffers.
      // A stall/pause must require fresh progress, not the old episode total.
      networkSafe = played - _baseline >= unknownBufferDelay;
    }
  }
}
