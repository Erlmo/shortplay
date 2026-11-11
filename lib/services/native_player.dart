import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';
import 'package:flutter/widgets.dart' show Size, ValueNotifier;

class NativePlayer {
  static const _channel = MethodChannel('shortplay/native_player');
  static const _events = EventChannel('shortplay/native_player/events');

  /// 由已加载的原生解码器报告能力；未加载解码器的平台保留兼容编码。
  static Future<bool> supportsByteVc2() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('supportsBvc2') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

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
  bool get isReusable =>
      !_disposed && _errorMessage == null && isCreated && _firstFrameRendered;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _wantsPlaying = false;
  int _transportRevision = 0;
  int _telemetryRevision = 0;
  bool _completed = false;
  bool _buffering = false;
  Duration? _bufferedAhead;
  bool _firstFrameRendered = false;
  int _videoWidth = 0;
  int _videoHeight = 0;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get wantsPlaying => _wantsPlaying;
  bool get completed => _completed;
  bool get buffering => _buffering;

  /// Null means this backend cannot report buffered duration.
  Duration? get bufferedAhead => _bufferedAhead;
  bool get firstFrameRendered => _firstFrameRendered;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;

  /// 视频显示尺寸。原生侧上报后立即更新，画面和横屏按钮据此重建；
  /// 只读 [videoWidth]/[videoHeight] 字段的话，要等下一次无关的 setState
  /// 才会生效（横屏片源会先按 9:16 被拉伸一会儿）。
  final ValueNotifier<Size> videoSizeNotifier = ValueNotifier(Size.zero);

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _intentCtrl = StreamController<bool>.broadcast();
  final _bufferedAheadCtrl = StreamController<Duration?>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _firstFrameCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playbackIntentStream => _intentCtrl.stream;
  Stream<Duration?> get bufferedAheadStream => _bufferedAheadCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  Stream<bool> get firstFrameStream => _firstFrameCtrl.stream;
  Stream<String> get errorStream => _errorCtrl.stream;

  // ─── 生命周期 ──────────────────────────────────────────────────────────

  final _createdCompleter = Completer<int>();

  Future<int> create(String cdnUrl, String keyHex, {int? initialPositionMs}) {
    if (_disposed) return Future.error(StateError('播放器已关闭'));
    return _creation ??= _create(cdnUrl, keyHex, initialPositionMs);
  }

  Future<int> _create(
      String cdnUrl, String keyHex, int? initialPositionMs) async {
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
        if (initialPositionMs != null && initialPositionMs >= 0)
          'initialPositionMs': initialPositionMs,
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

  void _setPlaybackIntent(bool value) {
    if (_disposed) return;
    ++_transportRevision;
    if (_wantsPlaying == value) return;
    _wantsPlaying = value;
    _intentCtrl.add(value);
  }

  /// A read-only native snapshot continues while position/isPlaying are frozen
  /// during a stall. A reply started before a seek/pause/event is discarded.
  Future<void> pollBufferState() async {
    final id = _playerId;
    if (_disposed || id == null || _errorMessage != null) return;
    final transport = _transportRevision;
    final telemetry = _telemetryRevision;
    Map<String, dynamic>? state;
    try {
      state = await _channel
          .invokeMapMethod<String, dynamic>('getBufferState', {'id': id});
    } on MissingPluginException {
      return;
    }
    if (state == null ||
        _disposed ||
        id != _playerId ||
        transport != _transportRevision ||
        telemetry != _telemetryRevision) {
      return;
    }
    for (final entry in const {
      'bufferedAheadMs': 'bufferedAhead',
      'positionMs': 'position',
      'durationMs': 'duration',
    }.entries) {
      final value = state[entry.key];
      if (value is num && value.isFinite && value >= 0) {
        if (entry.key == 'positionMs' &&
            value.toInt() == _position.inMilliseconds) {
          continue;
        }
        if (entry.key == 'durationMs' &&
            value.toInt() == _duration.inMilliseconds) {
          continue;
        }
        _handleEvent({'type': entry.value, 'value': value.toInt()});
      } else if (entry.key == 'bufferedAheadMs' &&
          value == null &&
          _bufferedAhead != null) {
        _bufferedAhead = null;
        _bufferedAheadCtrl.add(null);
      }
    }
    for (final field in ['buffering', 'playing', 'completed']) {
      final value = state[field];
      final previous = switch (field) {
        'buffering' => _buffering,
        'playing' => _playing,
        _ => _completed,
      };
      if (value is bool && value != previous) {
        _handleEvent({'type': field, 'value': value});
      }
    }
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

  final _transitions = PlaybackCommandQueue();
  Future<void> transition(Future<void> Function() operation) =>
      _transitions.run(operation);

  /// Prepare/render on the existing backend with its playback clock paused.
  /// The existing firstFrame event, not command completion, proves readiness.
  Future<void> prepareFirstFrame() async {
    _setPlaybackIntent(false);
    if (_disposed || _playerId == null) return;
    await _channel.invokeMethod('prepareFirstFrame', {'id': _playerId});
  }

  Future<void> play() async {
    if (_disposed || _playerId == null) return;
    _setPlaybackIntent(true);
    await _channel.invokeMethod('play', {'id': _playerId});
  }

  Future<void> pause() async {
    if (_disposed || _playerId == null) return;
    _setPlaybackIntent(false);
    await _channel.invokeMethod('pause', {'id': _playerId});
  }

  Future<void> seek(Duration position) async {
    if (_disposed || _playerId == null) return;
    ++_transportRevision;
    _bufferedAhead = null;
    await _channel.invokeMethod('seek', {
      'id': _playerId,
      'positionMs': position.inMilliseconds,
    });
    if (!_disposed) _completed = false;
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
    _setPlaybackIntent(false);
    _disposed = true;
    if (_creation != null && !_createdCompleter.isCompleted) {
      _createdCompleter.completeError(StateError('播放器已关闭'));
    }
    if (_playerId != null) {
      _instances.remove(_playerId);
      await _releaseNative(_playerId!);
    }
    if (!_firstFrameRendered && _firstFrameCtrl.hasListener) {
      _firstFrameCtrl.addError(StateError('播放器已关闭'));
    }
    _positionCtrl.close();
    _durationCtrl.close();
    _intentCtrl.close();
    _bufferedAheadCtrl.close();
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
    ++_telemetryRevision;
    final type = event['type'] as String?;
    if (const bool.fromEnvironment('SHORTPLAY_TRACE_STARTUP')) {
      if (type == 'buffering' || type == 'firstFrame' || type == 'error') {
        debugPrint('[StartupEvent] player=$_playerId type=$type '
            'value=${event['value']} epoch_ms=${DateTime.now().millisecondsSinceEpoch}');
      }
    }
    switch (type) {
      case 'created':
        final textureId = event['value'] as int;
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.complete(textureId);
        }
      case 'error':
        _setPlaybackIntent(false);
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
      case 'playbackIntent':
        // 原生音频冲突可能终止播放意图，避免卡顿恢复又把它启动。
        _setPlaybackIntent(event['value'] == true);
      case 'playing':
        if (_disposed) return;
        _playing = event['value'] as bool;
        _playingCtrl.add(_playing);
      case 'completed':
        if (_disposed) return;
        _completed = event['value'] as bool;
        if (_completed) _setPlaybackIntent(false);
        _completedCtrl.add(_completed);
      case 'bufferedAhead':
        final value = event['value'];
        if (value is num) {
          final ahead = Duration(milliseconds: value.toInt().clamp(0, 1 << 31));
          if (_bufferedAhead != ahead) {
            _bufferedAhead = ahead;
            _bufferedAheadCtrl.add(ahead);
          }
        }
        break;
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
