import 'dart:async';

import 'first_frame.dart';

/// A video ID alone cannot distinguish quality changes or a replaced playlist.
/// These extra identity fields are host safeguards, not TT's engine-pool ABI.
class PlaybackEngineKey {
  const PlaybackEngineKey(this.sourceId,
      {required this.revision, required this.variant, this.localPath});
  final String sourceId;
  final int revision;
  final String variant;
  final String? localPath;

  @override
  bool operator ==(Object other) =>
      other is PlaybackEngineKey &&
      sourceId == other.sourceId &&
      revision == other.revision &&
      variant == other.variant &&
      localPath == other.localPath;
  @override
  int get hashCode => Object.hash(sourceId, revision, variant, localPath);
}

class PrerenderTicket {
  PrerenderTicket._(this.key, this.cancellation);
  final PlaybackEngineKey key;
  final PlaybackCancellation cancellation;
}

/// Owns only parked engines. Taking an engine transfers ownership to playback;
/// subsequent background cancellation/eviction cannot release that engine.
/// Incomplete or failed engines are never published as reusable.
class PreparedPlaybackStore<T extends Object> {
  PreparedPlaybackStore({
    required this.isUsable,
    required this.release,
    this.capacity = 2,
  }) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }
  final bool Function(T) isUsable;
  final void Function(T) release;
  final int capacity;
  final _ready = <PlaybackEngineKey, T>{};
  PrerenderTicket? _pending;

  PrerenderTicket begin(PlaybackEngineKey key, PlaybackCancellation token) {
    cancel();
    return _pending = PrerenderTicket._(key, token);
  }

  bool isCurrent(PrerenderTicket ticket) =>
      identical(_pending, ticket) && !ticket.cancellation.isCancelled;

  bool publish(PrerenderTicket ticket, T engine) {
    if (!isCurrent(ticket) || !isUsable(engine)) return false;
    _pending = null;
    remember(ticket.key, engine);
    return true;
  }

  void finish(PrerenderTicket ticket) {
    if (identical(_pending, ticket)) _pending = null;
  }

  void cancel() {
    _pending?.cancellation.cancel();
    _pending = null;
  }

  bool contains(PlaybackEngineKey key, T engine) =>
      identical(_ready[key], engine) && isUsable(engine);

  void remember(PlaybackEngineKey key, T engine) {
    forget(engine);
    final old = _ready.remove(key);
    if (old != null && !identical(old, engine)) release(old);
    if (!isUsable(engine)) {
      release(engine);
      return;
    }
    _ready[key] = engine;
    while (_ready.length > capacity) {
      final stale = _ready.remove(_ready.keys.first)!;
      release(stale);
    }
  }

  T? take(PlaybackEngineKey key) {
    final engine = _ready.remove(key);
    if (engine == null) return null;
    if (!isUsable(engine)) {
      release(engine);
      return null;
    }
    return engine;
  }

  void forget(T engine) =>
      _ready.removeWhere((_, value) => identical(value, engine));

  void clear() {
    cancel();
    final engines = _ready.values.toSet();
    _ready.clear();
    for (final engine in engines) {
      release(engine);
    }
  }
}

/// One engine's park/promote transaction must finish before the next one.
/// A rejected transaction does not poison subsequent engine operations.
class PlaybackCommandQueue {
  Future<void> _tail = Future<void>.value();
  Future<void> run(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}

/// Promotion is ordered and cancellable between native commands. In particular,
/// a completed previous engine is rewound before audio/play are re-enabled.
Future<void> activatePreparedPlayback({
  required PlaybackCancellation cancellation,
  required Future<void> Function() activate,
  required Future<void> Function() position,
  required Future<void> Function() rate,
  required Future<void> Function() unmute,
  required Future<void> Function() play,
}) async {
  for (final step in [activate, position, rate, unmute, play]) {
    cancellation.check();
    await cancellation.wait(step());
  }
  cancellation.check();
}
