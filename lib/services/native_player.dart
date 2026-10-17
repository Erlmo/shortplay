import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Size, ValueNotifier;

class NativePlayer {
  static const _channel = MethodChannel('shortplay/native_player');
  static const _events = EventChannel('shortplay/native_player/events');

  static StreamSubscription? _globalEventSub;
  static final Map<int, NativePlayer> _instances = {};
  static final Set<NativePlayer> _creating = {};
  // 本地文件创建很快，事件可能先于 MethodChannel 的 create 返回。
  // 仅在创建期间暂存各类最新事件，注册 playerId 后立即回放。
  static final Map<int, Map<String, Map<Object?, Object?>>> _earlyEvents = {};
  static const _creationTimeout = Duration(seconds: 15);

  static void _ensureGlobalListener() {
    if (_globalEventSub != null) return;
    _globalEventSub = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final playerId = event['playerId'] as int?;
      if (playerId == null) return;
      final player = _instances[playerId];
      if (player != null) {
        player._handleEvent(event);
      } else if (_creating.isNotEmpty &&
          (_earlyEvents.containsKey(playerId) || _earlyEvents.length < 8)) {
        final type = event['type'];
        if (type is String) {
          (_earlyEvents[playerId] ??= {})[type] =
              Map<Object?, Object?>.of(event);
        }
      }
    }, onError: (Object error) {
      for (final player in {..._instances.values, ..._creating}) {
        player._handleEvent({'type': 'error', 'value': '播放器事件通道异常：$error'});
      }
    });
  }

  @visibleForTesting
  static Future<void> resetEventListenerForTesting() async {
    assert(_instances.isEmpty && _creating.isEmpty);
    await _globalEventSub?.cancel();
    _globalEventSub = null;
    _earlyEvents.clear();
  }

  int? _playerId;
  int? _textureId;
  bool _disposed = false;
  bool _releaseRequested = false;
  Future<int>? _creation;
  String? _errorMessage;

  int? get textureId => _textureId;
  bool get isCreated => _textureId != null;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _completed = false;
  bool _buffering = false;
  bool _firstFrameRendered = false;
  int _videoWidth = 0;
  int _videoHeight = 0;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get completed => _completed;
  bool get buffering => _buffering;
  bool get firstFrameRendered => _firstFrameRendered;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;

  /// 视频显示尺寸。原生侧上报后立即更新，画面和横屏按钮据此重建；
  /// 只读 [videoWidth]/[videoHeight] 字段的话，要等下一次无关的 setState
  /// 才会生效（横屏片源会先按 9:16 被拉伸一会儿）。
  final ValueNotifier<Size> videoSizeNotifier = ValueNotifier(Size.zero);

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _firstFrameCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  Stream<bool> get firstFrameStream => _firstFrameCtrl.stream;
  Stream<String> get errorStream => _errorCtrl.stream;

  // ─── 生命周期 ──────────────────────────────────────────────────────────

  final _createdCompleter = Completer<int>();

  Future<int> create(String cdnUrl, String keyHex) {
    if (_disposed) return Future.error(StateError('播放器已关闭'));
    return _creation ??= _create(cdnUrl, keyHex);
  }

  Future<int> _create(String cdnUrl, String keyHex) async {
    // 提前处理 ready 的错误；等待 create 应答期间取消或早到 error 也不会
    // 产生未处理异常，随后 await 仍会把同一错误返回给调用者。
    final ready = _createdCompleter.future;
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _creating.add(this);
    try {
      _ensureGlobalListener();
      final response = _channel.invokeMapMethod<String, dynamic>('create', {
        'cdnUrl': cdnUrl,
        'keyHex': keyHex,
      });
      // 超时/退出后原生才返回 id 时，仍需释放原生实例。
      unawaited(response.then<void>((result) {
        final id = result?['playerId'];
        if (_disposed && id is int) unawaited(_releaseNative(id));
      }, onError: (Object _, StackTrace __) {}));
      final result = await response.timeout(_creationTimeout);
      final id = result?['playerId'];
      if (id is! int) throw StateError('播放器未返回有效标识');
      _playerId = id;
      if (_disposed) {
        await _releaseNative(id);
        throw StateError('播放器已关闭');
      }
      _instances[id] = this;
      final events = _earlyEvents.remove(id);
      if (events != null) {
        for (final event in events.values) {
          _handleEvent(event);
        }
      }
      final returnedTexture = result?['textureId'];
      if (returnedTexture is int &&
          returnedTexture >= 0 &&
          !_createdCompleter.isCompleted) {
        _createdCompleter.complete(returnedTexture);
      }
      _textureId = await ready.timeout(_creationTimeout);
      return _textureId!;
    } catch (_) {
      await dispose();
      rethrow;
    } finally {
      _creating.remove(this);
      if (_creating.isEmpty) _earlyEvents.clear();
    }
  }

  /// 同时检查早到的播放错误，避免错过首帧前的错误后一直等待。
  Future<void> waitForFirstFrame(
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (_errorMessage != null) throw StateError(_errorMessage!);
    if (_disposed) throw StateError('播放器已关闭');
    if (_firstFrameRendered) return;
    await firstFrameStream.firstWhere((rendered) => rendered).timeout(timeout);
  }

  Future<void> _releaseNative(int id) async {
    if (_releaseRequested) return;
    _releaseRequested = true;
    try {
      await _channel.invokeMethod('dispose', {'id': id});
    } catch (_) {
      // 引擎退出或实例已释放时无需再次释放。
    }
  }

  Future<void> play() async {
    if (_disposed || _playerId == null) return;
    await _channel.invokeMethod('play', {'id': _playerId});
  }

  Future<void> pause() async {
    if (_disposed || _playerId == null) return;
    await _channel.invokeMethod('pause', {'id': _playerId});
  }

  Future<void> seek(Duration position) async {
    if (_disposed || _playerId == null) return;
    await _channel.invokeMethod('seek', {
      'id': _playerId,
      'positionMs': position.inMilliseconds,
    });
  }

  Future<void> setVolume(double volume) async {
    if (_disposed || _playerId == null) return;
    await _channel.invokeMethod('setVolume', {
      'id': _playerId,
      'volume': volume,
    });
  }

  Future<void> setRate(double rate) async {
    if (_disposed || _playerId == null) return;
    await _channel.invokeMethod('setRate', {
      'id': _playerId,
      'rate': rate,
    });
  }

  /// 停放(false)/激活(true)底层加密流。停放后只再预取约 1MB，暂停中的
  /// 上一集/下一集播放器不再和当前集抢带宽；激活后恢复正常预读。
  Future<void> setActive(bool active) async {
    if (_disposed || _playerId == null) return;
    await _channel
        .invokeMethod('setActive', {'id': _playerId, 'active': active});
  }

  static Future<void> setKeepScreenOn(bool on) async {
    await _channel.invokeMethod('setKeepScreenOn', {'on': on});
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_creation != null && !_createdCompleter.isCompleted) {
      _createdCompleter.completeError(StateError('播放器已关闭'));
    }
    if (_playerId != null) {
      _instances.remove(_playerId);
      await _releaseNative(_playerId!);
    }
    _positionCtrl.close();
    _durationCtrl.close();
    _playingCtrl.close();
    _completedCtrl.close();
    _bufferingCtrl.close();
    _firstFrameCtrl.close();
    _errorCtrl.close();
    // videoSizeNotifier 不 dispose：页面上的 ValueListenableBuilder 可能晚于
    // 播放器释放才移除监听，交给 GC 回收即可。
  }

  // ─── 事件处理 ──────────────────────────────────────────────────────────

  void _handleEvent(dynamic event) {
    if (_disposed || event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'created':
        final textureId = event['value'] as int;
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.complete(textureId);
        }
      case 'error':
        final message = event['value']?.toString() ?? '播放失败';
        _errorMessage = message;
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.completeError(StateError(message));
        }
        if (!_firstFrameRendered && _firstFrameCtrl.hasListener) {
          _firstFrameCtrl.addError(StateError(message));
        }
        _errorCtrl.add(message);
      case 'position':
        if (_disposed) return;
        final ms = event['value'] as int;
        _position = Duration(milliseconds: ms);
        _positionCtrl.add(_position);
      case 'duration':
        if (_disposed) return;
        final ms = event['value'] as int;
        _duration = Duration(milliseconds: ms);
        _durationCtrl.add(_duration);
      case 'playing':
        if (_disposed) return;
        _playing = event['value'] as bool;
        _playingCtrl.add(_playing);
      case 'completed':
        if (_disposed) return;
        _completed = event['value'] as bool;
        _completedCtrl.add(_completed);
      case 'buffering':
        if (_disposed) return;
        _buffering = event['value'] as bool;
        _bufferingCtrl.add(_buffering);
      case 'firstFrame':
        if (_disposed) return;
        _firstFrameRendered = true;
        _firstFrameCtrl.add(true);
      case 'videoSize':
        if (_disposed) return;
        _videoWidth = event['width'] as int;
        _videoHeight = event['height'] as int;
        videoSizeNotifier.value =
            Size(_videoWidth.toDouble(), _videoHeight.toDouble());
    }
  }
}
