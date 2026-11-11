import 'dart:async';

import 'first_frame.dart';
import 'buffer_scheduling.dart';

/// Values observed in TT SDK 1.52.1.13 StrategyPreloadConfig. The fallback and
/// cache capacity are our adapters' choices, not claims about its native engine.
class PlaybackPolicy {
  const PlaybackPolicy({
    this.startBuffer = const Duration(seconds: 14),
    this.stopBuffer = const Duration(seconds: 5),
    this.preloadCount = 3,
    this.maxFailures = 3,
    this.unknownBufferDelay = const Duration(seconds: 3),
  });

  final Duration startBuffer;
  final Duration stopBuffer;
  final int preloadCount;
  final int maxFailures;
  final Duration unknownBufferDelay;
}

class PlaybackSource {
  const PlaybackSource(this.id, {this.local = false});
  final String id;
  final bool local;
}

enum PlaybackWork { firstFrame, header }

typedef PlaybackWorkRunner = Future<bool> Function(
    int index, PlaybackWork work, PlaybackCancellation cancellation);

/// One speculative worker; foreground playback never waits for this queue.
/// Buffer hysteresis avoids stopping/restarting on every progress event.
/// Only the next source consumes an extra decoder. More distant sources warm
/// headers through the application's existing IO/cache implementation.
class PlaybackSession {
  PlaybackSession({
    required this.run,
    this.policy = const PlaybackPolicy(),
    this.onError,
    this.isLocal,
    this.isPreloaded,
  });

  final PlaybackWorkRunner run;
  final bool Function(int index)? isLocal;
  final bool Function(int index)? isPreloaded;
  final PlaybackPolicy policy;
  final void Function(Object error, StackTrace stack)? onError;
  List<PlaybackSource> _sources = const [];
  int _index = -1;
  int _epoch = 0;
  bool _closed = false;
  bool _enabled = false;
  bool _firstFrame = false;
  late final _bufferGate = PlaybackBufferGate(
    startBuffer: policy.startBuffer,
    stopBuffer: policy.stopBuffer,
    unknownBufferDelay: policy.unknownBufferDelay,
  );
  bool get _networkSafe => _bufferGate.networkSafe;
  bool get canPreloadNetwork => _enabled && _networkSafe;
  bool _running = false;
  bool _pendingWake = false;
  final Set<String> _done = {};
  final Map<String, int> _failures = {};
  final Map<String, Future<bool> Function(PlaybackCancellation)> _background =
      {};

  /// Low-priority network work (e.g. the next season) shares this session's
  /// cancellation and bandwidth gate instead of bypassing the worker.
  void enqueue(String key, Future<bool> Function(PlaybackCancellation) task) {
    if (_closed || _index < 0) return;
    _background.putIfAbsent('background:$key', () => task);
    _wake();
  }

  PlaybackCancellation? _job;
  bool _jobUsesNetwork = false;

  void start(List<PlaybackSource> sources, int currentIndex) {
    if (_closed) return;
    cancel();
    _sources = List.unmodifiable(sources);
    _index = currentIndex;
    _done.clear();
    _failures.clear();
    _background.clear();
    _firstFrame = false;
    _bufferGate.reset();
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
    if (_closed || _index < 0 || _index >= _sources.length) return;
    _firstFrame = firstFrame;
    _bufferGate.update(
      firstFrame: firstFrame,
      buffering: buffering,
      active: active,
      played: played,
      bufferedAhead: bufferedAhead,
      fullyBuffered: fullyBuffered,
      position: position,
      duration: duration,
    );
    _enabled = _bufferGate.enabled;
    if (!_enabled || (!_networkSafe && _jobUsesNetwork)) {
      _job?.cancel();
    }
    _wake();
  }

  /// Called before seek/switch/leave. The active engine itself is owned by the
  /// page; only speculative work is cancelled here.
  void cancel() {
    ++_epoch;
    _enabled = false;
    _bufferGate.reset();
    _job?.cancel();
  }

  void close() {
    _closed = true;
    cancel();
    _sources = const [];
  }

  void _wake() {
    if (_running) {
      _pendingWake = true;
      return;
    }
    if (_closed || !_enabled || !_firstFrame) return;
    _running = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    final epoch = _epoch;
    try {
      for (var offset = 1; offset <= policy.preloadCount; offset++) {
        final target = _index + offset;
        if (_closed ||
            epoch != _epoch ||
            !_enabled ||
            target >= _sources.length) {
          break;
        }
        final source = _sources[target];
        if (source.id.isEmpty) continue;
        final local = isLocal?.call(target) ?? source.local;
        final preloaded = offset == 1 && (isPreloaded?.call(target) ?? false);
        if (!_networkSafe && !local && !preloaded) break;
        if (local && offset > 1) continue;
        final work =
            offset == 1 ? PlaybackWork.firstFrame : PlaybackWork.header;
        final key = '${work.name}:${source.id}';
        if (_done.contains(key) ||
            (_failures[key] ?? 0) >= policy.maxFailures) {
          continue;
        }
        final cancellation = PlaybackCancellation();
        _job = cancellation;
        _jobUsesNetwork = !local && !preloaded;
        bool success = false;
        try {
          success = await run(target, work, cancellation);
        } on PlaybackCancelled {
          // Cancellation is not a failure and must not consume retries.
        } catch (error, stack) {
          onError?.call(error, stack);
        }
        if (_closed || epoch != _epoch || cancellation.isCancelled) break;
        if (success) {
          _done.add(key);
        } else {
          _failures[key] = (_failures[key] ?? 0) + 1;
          // Retry only on a later state update, never spin on a failed request.
          return;
        }
      }
      for (final key in _background.keys.toList()) {
        if (_closed || epoch != _epoch || !_enabled || !_networkSafe) break;
        if (_done.contains(key) ||
            (_failures[key] ?? 0) >= policy.maxFailures) {
          continue;
        }
        final task = _background[key];
        if (task == null) continue;
        final cancellation = PlaybackCancellation();
        _job = cancellation;
        _jobUsesNetwork = true;
        var success = false;
        try {
          success = await task(cancellation);
        } on PlaybackCancelled {
          // Foreground changes do not count as network failures.
        } catch (error, stack) {
          onError?.call(error, stack);
        }
        if (_closed || epoch != _epoch || cancellation.isCancelled) break;
        if (success) {
          _done.add(key);
          _background.remove(key);
        } else {
          _failures[key] = (_failures[key] ?? 0) + 1;
          break;
        }
      }
    } finally {
      _job = null;
      _jobUsesNetwork = false;
      _running = false;
      final pendingWake = _pendingWake;
      _pendingWake = false;
      if (pendingWake) _wake();
    }
  }
}
