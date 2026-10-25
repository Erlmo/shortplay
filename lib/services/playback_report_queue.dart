import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playback_report_book.dart';

typedef _WatchCheckpoint = ({
  int sequence,
  String bookId,
  String itemId,
  int positionMs,
  int playedDeltaMs,
  int vidIndex,
  int timestampMs,
});

typedef _OwnerSnapshot = ({
  String? owner,
  Object? error,
  StackTrace? stackTrace
});

/// 按剧合并观看记录。成功确认前保留本地队列，旧请求不能删除更新的进度。
class PlaybackReportQueue {
  PlaybackReportQueue({
    required Future<void> Function(List<PlaybackReportBook>, String owner)
        sender,
    required Future<String?> Function() currentOwner,
    required Future<String> Function() verifiedOwner,
    int Function()? timestampMs,
    Future<SharedPreferences> Function()? preferencesLoader,
    VoidCallback? onAccepted,
  })  : _sender = sender,
        _currentOwner = currentOwner,
        _verifiedOwner = verifiedOwner,
        _timestampMs = timestampMs ?? _nowMs,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _onAccepted = onAccepted;

  static const storageKey = 'playback_report_queue_v1';
  static const maxBatchSize = 50;

  final Future<void> Function(List<PlaybackReportBook>, String owner) _sender;
  final Future<String?> Function() _currentOwner;
  final Future<String> Function() _verifiedOwner;
  final int Function() _timestampMs;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final VoidCallback? _onAccepted;
  final Map<String, int> _cumulative = {};
  final Map<String, PlaybackReportBook> _pending = {};
  final Map<String, int> _revisions = {};
  final Map<String, PlaybackReportBook> _latest = {};
  final Map<String, int> _latestSequence = {};
  int _checkpointSequence = 0;
  final Map<int, _WatchCheckpoint> _staged = {};
  final Map<int, Future<_OwnerSnapshot>> _stagedOwners = {};
  SharedPreferences? _preferences;
  Future<void>? _loading;
  Future<void>? _flushing;
  bool _flushAgainRequested = false;
  Future<void> _saving = Future.value();
  String? _owner;
  int _ownerEpoch = 0;
  int _failures = 0;
  int _nextAttemptMs = 0;

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  Future<void> checkpoint({
    required String bookId,
    required String itemId,
    required int positionMs,
    required int playedDeltaMs,
    required int vidIndex,
    required int timestampMs,
  }) async {
    final sequence = ++_checkpointSequence;
    if (!PlaybackReportBook.validId(bookId) ||
        !PlaybackReportBook.validId(itemId) ||
        positionMs < 0 ||
        playedDeltaMs < 0 ||
        vidIndex < 1 ||
        timestampMs < 1) {
      throw const FormatException('观看记录格式无效');
    }
    final operation = (
      sequence: sequence,
      bookId: bookId,
      itemId: itemId,
      positionMs: positionMs,
      playedDeltaMs: playedDeltaMs,
      vidIndex: vidIndex,
      timestampMs: timestampMs,
    );
    // 在任何可能失败的 I/O 前接纳。session 结束后读取暂时失败，也由队列继续持有。
    _staged[sequence] = operation;
    _stagedOwners[sequence] = _readOwnerSnapshot();
    await _applyCheckpoint(operation);
  }

  Future<_OwnerSnapshot> _readOwnerSnapshot() async {
    try {
      return (owner: await _currentOwner(), error: null, stackTrace: null);
    } catch (error, stackTrace) {
      return (owner: null, error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _applyCheckpoint(_WatchCheckpoint operation) async {
    await _ensureLoaded();
    final snapshotFuture = _stagedOwners[operation.sequence];
    if (snapshotFuture == null) return;
    var snapshot = await snapshotFuture;
    if (snapshot.error != null) {
      final retry = _readOwnerSnapshot();
      _stagedOwners[operation.sequence] = retry;
      snapshot = await retry;
      if (snapshot.error != null) {
        Error.throwWithStackTrace(snapshot.error!, snapshot.stackTrace!);
      }
    }
    final owner = await _currentOwner();
    if (!_staged.containsKey(operation.sequence)) return;
    _staged.remove(operation.sequence);
    _stagedOwners.remove(operation.sequence);
    if (snapshot.owner != null && snapshot.owner != owner) return;
    _switchOwner(owner);
    final bookId = operation.bookId;
    final total = (_cumulative[bookId] ?? 0) + operation.playedDeltaMs;
    _cumulative[bookId] = total;
    final incoming = PlaybackReportBook(
      bookId: bookId,
      itemId: operation.itemId,
      currentPlayTime: operation.positionMs,
      cumulativeDuration: total,
      readTimestampMs: operation.timestampMs,
      vidIndex: operation.vidIndex,
    );
    if (operation.sequence >= (_latestSequence[bookId] ?? 0)) {
      _latest[bookId] = incoming;
      _latestSequence[bookId] = operation.sequence;
    }
    final latest = _latest[bookId]!;
    _pending[bookId] = PlaybackReportBook(
      bookId: bookId,
      itemId: latest.itemId,
      currentPlayTime: latest.currentPlayTime,
      cumulativeDuration: total,
      readTimestampMs: latest.readTimestampMs,
      vidIndex: latest.vidIndex,
    );
    _revisions[bookId] = (_revisions[bookId] ?? 0) + 1;
    await _persist();
  }

  Future<void> flush({bool force = false}) {
    if (_flushing != null) {
      _flushAgainRequested = true;
      return _flushing!;
    }
    if (!force && _timestampMs() < _nextAttemptMs) return Future.value();
    return _flushing = _flushPending();
  }

  Future<void> _flushPending() async {
    try {
      await _ensureLoaded();
      for (final operation in _staged.values.toList(growable: false)) {
        await _applyCheckpoint(operation);
      }
      if (_pending.isEmpty) return;
      final verifiedOwner = await _verifiedOwner();
      if (_owner != null && _owner != verifiedOwner) {
        _switchOwner(verifiedOwner);
        await _persist();
        return;
      }
      _owner = verifiedOwner;
      final ownerEpoch = _ownerEpoch;
      // 一轮只发送开始时的快照。期间更新的记录留给下一次触发，避免无限循环。
      final snapshot = _pending.values
          .map((book) => (book: book, revision: _revisions[book.bookId]!))
          .toList(growable: false);
      for (var start = 0; start < snapshot.length; start += maxBatchSize) {
        final batch =
            snapshot.sublist(start, min(start + maxBatchSize, snapshot.length));
        try {
          await _sender(
            batch.map((entry) => entry.book).toList(growable: false),
            verifiedOwner,
          );
        } catch (error) {
          _deferRetry();
          debugPrint('观看记录尚未同步，将在下次触发时重试');
          return;
        }
        if (_owner != verifiedOwner || _ownerEpoch != ownerEpoch) return;
        _failures = 0;
        _nextAttemptMs = 0;
        for (final entry in batch) {
          if (_revisions[entry.book.bookId] == entry.revision) {
            _pending.remove(entry.book.bookId);
          }
        }
        await _persist();
        _onAccepted?.call();
      }
    } catch (error) {
      _deferRetry();
      debugPrint('本地观看记录同步暂不可用，将在下次触发时重试');
    } finally {
      _flushing = null;
      final followUp = _flushAgainRequested;
      _flushAgainRequested = false;
      if (followUp && (_pending.isNotEmpty || _staged.isNotEmpty)) {
        // 只响应发送期间显式到来的新 flush，不自行轮询；失败退避仍然生效。
        unawaited(flush());
      }
    }
  }

  void _deferRetry() {
    final seconds = min(60, 5 * (1 << min(_failures, 4)));
    _failures++;
    _nextAttemptMs = _timestampMs() + seconds * 1000;
  }

  Future<void> _ensureLoaded() {
    if (_loading != null) return _loading!;
    final attempt = _load();
    _loading = attempt;
    unawaited(attempt.then<void>((_) {}, onError: (Object _, StackTrace __) {
      if (identical(_loading, attempt)) _loading = null;
    }));
    return attempt;
  }

  Future<void> _load() async {
    try {
      final prefs = await _preferencesLoader();
      _preferences = prefs;
      final cached = prefs.get(storageKey);
      if (cached == null) {
        _owner = await _currentOwner();
        return;
      }
      if (cached is! String) throw const FormatException('观看队列类型无效');
      final decoded = jsonDecode(cached);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          (decoded['owner'] != null && decoded['owner'] is! String) ||
          decoded['cumulative'] is! Map ||
          decoded['pending'] is! List) {
        throw const FormatException('观看队列格式无效');
      }
      final cumulative = <String, int>{};
      final pending = <String, PlaybackReportBook>{};
      for (final entry in (decoded['cumulative'] as Map).entries) {
        if (entry.key is! String ||
            !PlaybackReportBook.validId(entry.key as String) ||
            entry.value is! int ||
            (entry.value as int) < 0) {
          throw const FormatException('观看累计格式无效');
        }
        cumulative[entry.key as String] = entry.value as int;
      }
      for (final value in decoded['pending'] as List) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('观看队列条目无效');
        }
        final book = PlaybackReportBook.fromJson(value);
        pending[book.bookId] = book;
        cumulative[book.bookId] =
            max(cumulative[book.bookId] ?? 0, book.cumulativeDuration);
      }
      _cumulative.addAll(cumulative);
      _pending.addAll(pending);
      _latest.addAll(pending);
      _owner = decoded['owner'] as String?;
      for (final id in pending.keys) {
        _revisions[id] = 1;
      }
      if (_switchOwner(await _currentOwner())) await _persist();
    } on FormatException {
      if (!await _preferences!.remove(storageKey)) {
        throw StateError('清理损坏的观看队列失败');
      }
    } catch (_) {
      // 读取失败允许下次重试，不能把没有读到的状态当作空队列覆盖。
      _loading = null;
      rethrow;
    }
  }

  bool _switchOwner(String? owner) {
    if (_owner == owner) return false;
    // 首次安装离线观看尚未注册，后续可绑定首次身份；已有身份变更则丢弃旧队列。
    if (_owner != null) {
      _cumulative.clear();
      _pending.clear();
      _revisions.clear();
      _latest.clear();
      _latestSequence.clear();
      _ownerEpoch++;
    }
    _owner = owner;
    return true;
  }

  Future<void> _persist() {
    final snapshot = jsonEncode({
      'version': 1,
      'owner': _owner,
      'cumulative': _cumulative,
      'pending': _pending.values.map((book) => book.toJson()).toList(),
    });
    final future = _saving.catchError((Object _) {}).then((_) async {
      if (!await _preferences!.setString(storageKey, snapshot)) {
        throw StateError('保存观看记录失败');
      }
    });
    _saving = future;
    return future;
  }
}
