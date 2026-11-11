import 'dart:async';

/// Cooperative cancellation: a cancelled background job must not publish a
/// player or an address into a newer playback session.
class PlaybackCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const PlaybackCancelled();
  }

  Future<T> wait<T>(Future<T> future) {
    return Future.any([
      future,
      _cancelled.future.then<T>((_) => throw const PlaybackCancelled()),
    ]);
  }
}

class PlaybackCancelled implements Exception {
  const PlaybackCancelled();
}

/// The caller owns the engine. A failure/cancellation must dispose it in a
/// finally block. Prefer prepare (paused prerender); play remains an optional
/// compatibility callback for external hosts lacking that operation.
/// This adapter deliberately uses the existing decoder and
/// rendering surface rather than importing any proprietary engine code.
Future<void> prepareFirstFrame({
  required PlaybackCancellation cancellation,
  required Future<void> Function() mute,
  Future<void> Function()? play,
  Future<void> Function()? prepare,
  required Future<void> Function() waitForFrame,
  required Future<void> Function() pause,
  required Future<void> Function() park,
}) async {
  cancellation.check();
  await cancellation.wait(mute());
  cancellation.check();
  final start = prepare ?? play;
  if (start == null) throw ArgumentError('Missing engine prepare callback');
  await cancellation.wait(start());
  cancellation.check();
  await cancellation.wait(waitForFrame());
  cancellation.check();
  await cancellation.wait(pause());
  cancellation.check();
  await cancellation.wait(park());
  cancellation.check();
}
