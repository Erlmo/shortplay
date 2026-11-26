import 'dart:async';

/// 播放页的屏幕常亮管理：正在播放时常亮，停止播放超过 [idleGrace] 后
/// 恢复系统自动熄屏。
///
/// 停止播放包括：全剧播完、用户暂停、播放出错、加载一直卡住、被其他页面盖住。
/// 留出宽限期是为了切集、短暂缓冲时不反复开关常亮——清掉常亮标记时，
/// 如果用户已经很久没碰屏幕，系统会马上熄屏。
class ScreenAwakeController {
  ScreenAwakeController({
    required Future<void> Function(bool on) setKeepScreenOn,
    this.idleGrace = const Duration(seconds: 30),
  }) : _setKeepScreenOn = setKeepScreenOn;

  final Future<void> Function(bool on) _setKeepScreenOn;
  final Duration idleGrace;

  bool? _on;
  bool _playing = false;
  Timer? _releaseTimer;
  bool _disposed = false;

  /// 准备开始播放（进入播放页、切集、继续播放）：先常亮，
  /// 如果宽限期内一直没真正播起来就放开。
  void hold() {
    if (_disposed) return;
    _apply(true);
    if (!_playing) _armRelease();
  }

  /// 播放器的实际播放状态变化。
  void setPlaying(bool playing) {
    if (_disposed) return;
    _playing = playing;
    if (playing) {
      _releaseTimer?.cancel();
      _releaseTimer = null;
      _apply(true);
    } else if (_on == true) {
      _armRelease();
    }
  }

  /// 立即恢复自动熄屏（定时停止播放）。
  void release() {
    if (_disposed) return;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _apply(false);
  }

  /// 退出播放页：恢复自动熄屏并停止计时。
  void dispose() {
    release();
    _disposed = true;
  }

  void _armRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(idleGrace, () {
      _releaseTimer = null;
      _apply(false);
    });
  }

  void _apply(bool on) {
    if (_on == on) return;
    _on = on;
    unawaited(_setKeepScreenOn(on).catchError((Object _) {}));
  }
}
