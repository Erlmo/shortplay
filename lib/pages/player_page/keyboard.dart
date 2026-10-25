part of '../player_page.dart';

// 遥控器/键盘：上下切集，左右快退/快进 10 秒，OK/回车/空格 暂停播放，
// 长按 OK 或菜单键（M）打开播放菜单（选集/倍速/清晰度/定时/弹幕/下载），
// E 直接打开选集。电视返回键先隐藏屏显，再退出播放页。
final _okKeys = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.gameButtonA,
};

final _prevEpisodeKeys = {
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.channelUp,
  LogicalKeyboardKey.pageUp,
};

final _nextEpisodeKeys = {
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.channelDown,
  LogicalKeyboardKey.pageDown,
};

final _menuKeys = {
  LogicalKeyboardKey.contextMenu,
  LogicalKeyboardKey.info,
  LogicalKeyboardKey.keyM,
};

extension _PlayerKeyboard on _PlayerPageState {
  KeyEventResult _onPlayerKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_okKeys.contains(key)) {
      _onOkKey(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isDown = event is KeyDownEvent;
    if (key == LogicalKeyboardKey.escape && DeviceProfile.isTv) {
      if (isDown) _onBack();
      return KeyEventResult.handled;
    }
    if (_prevEpisodeKeys.contains(key)) {
      if (isDown) _stepEpisode(-1);
      return KeyEventResult.handled;
    }
    if (_nextEpisodeKeys.contains(key)) {
      if (isDown) _stepEpisode(1);
      return KeyEventResult.handled;
    }
    // 快退 / 快进：按住时随重复事件连续跳
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-10000);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(10000);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (isDown) _onTogglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      final wantPlay = key == LogicalKeyboardKey.mediaPlay;
      if (isDown && playingNotifier.value != wantPlay) _onTogglePlay();
      return KeyEventResult.handled;
    }
    if (_menuKeys.contains(key)) {
      if (isDown) unawaited(_openMoreMenu());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE) {
      if (isDown) unawaited(_onEpisodeTap());
      return KeyEventResult.handled;
    }
    // F：横屏全屏 / 退出（桌面键盘、外接键盘）
    if (key == LogicalKeyboardKey.keyF && !DeviceProfile.isTv) {
      if (isDown) _onToggleLandscapeFullScreen();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// OK 键：短按暂停/播放，长按（600ms 或系统开始发重复事件）打开菜单。
  void _onOkKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      _okHoldTimer?.cancel();
      _okHoldTimer = Timer(const Duration(milliseconds: 600), () {
        _okHoldTimer = null;
        unawaited(_openMoreMenu());
      });
    } else if (event is KeyRepeatEvent) {
      // 系统按住约 0.5 秒后开始发重复事件：这就是长按，立即打开菜单
      if (_okHoldTimer != null) {
        _okHoldTimer!.cancel();
        _okHoldTimer = null;
        unawaited(_openMoreMenu());
      }
    } else if (event is KeyUpEvent) {
      if (_okHoldTimer != null) {
        _okHoldTimer!.cancel();
        _okHoldTimer = null;
        _systemUi.showUIAndResetTimer();
        _onTogglePlay();
      }
    }
  }

  void _flashKeyHint() {
    if (!DeviceProfile.isTv) return;
    _refresh(() => _showKeyHint = true);
    _keyHintTimer?.cancel();
    _keyHintTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) _refresh(() => _showKeyHint = false);
    });
  }
}
