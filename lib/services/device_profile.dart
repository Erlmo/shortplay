import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 运行设备的形态。启动时 [init] 一次，之后同步读取。
class DeviceProfile {
  DeviceProfile._();

  static const MethodChannel _channel = MethodChannel('shortplay/device');

  /// Android TV / 电视盒子（UI_MODE_TYPE_TELEVISION 或 leanback 特性）。
  static bool isTv = false;

  /// 主要靠方向键/键盘操作的设备：电视和桌面。这些设备上可点区域需要
  /// 可聚焦、并显示明显的焦点框；手机上保持原有触控行为不变。
  ///
  /// 用 [defaultTargetPlatform] 而不是 `Platform`：`flutter test` 跑在 macOS
  /// 宿主上但模拟的是 Android 手机，不能被当成桌面。
  static bool get usesFocusUi =>
      isTv ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// 电视模式在手机 / 电视之间切换时 +1，根组件据此整棵重建。
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// 设置页里的"电视模式"选项，默认自动识别。
  static final ValueNotifier<TvModeSetting> tvMode =
      ValueNotifier(TvModeSetting.auto);

  /// 自动识别的结果（系统特性或遥控器按键），不受手动设置影响。
  static bool get autoDetectedTv => _nativeTv || _remoteTv;

  static const String _remoteDetectedKey = 'device_profile.remote_detected';
  static const String _tvModeKey = 'device_profile.tv_mode';
  static bool _nativeTv = false;
  static bool _remoteTv = false;
  static bool _listeningRemote = false;
  static int _arrowPresses = 0;

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      _nativeTv = await _channel.invokeMethod<bool>('isTv') ?? false;
    } catch (e) {
      debugPrint('DeviceProfile.isTv 检测失败: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _remoteTv = prefs.getBool(_remoteDetectedKey) ?? false;
      tvMode.value = _parseMode(prefs.getString(_tvModeKey));
    } catch (e) {
      debugPrint('读取电视模式设置失败: $e');
    }
    isTv = _resolve();
    _syncRemoteListener();
  }

  /// 手动切换电视模式。结果变化时 [revision] +1，界面整棵重建并回到首页。
  static Future<void> setTvMode(TvModeSetting mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tvModeKey, mode.name);
    tvMode.value = mode;
    _apply();
  }

  static TvModeSetting _parseMode(String? raw) => TvModeSetting.values
      .firstWhere((m) => m.name == raw, orElse: () => TvModeSetting.auto);

  static bool _resolve() => switch (tvMode.value) {
        TvModeSetting.on => true,
        TvModeSetting.off => false,
        TvModeSetting.auto => autoDetectedTv,
      };

  static void _apply() {
    _syncRemoteListener();
    final next = _resolve();
    if (next == isTv) return;
    isTv = next;
    revision.value++;
  }

  /// 只有"自动"且还没认出电视时才监听遥控器按键。
  /// 有的盒子系统层面完全伪装成手机，只能看用户是不是在用遥控器。
  static void _syncRemoteListener() {
    final need = tvMode.value == TvModeSetting.auto && !autoDetectedTv;
    if (need && !_listeningRemote) {
      _arrowPresses = 0;
      HardwareKeyboard.instance.addHandler(_detectRemote);
      _listeningRemote = true;
    } else if (!need && _listeningRemote) {
      HardwareKeyboard.instance.removeHandler(_detectRemote);
      _listeningRemote = false;
    }
  }

  /// 遥控器确认键（DPAD_CENTER）直接认定；方向键连按 3 次才认定，
  /// 避免手机接了蓝牙键盘被误判。
  static bool _detectRemote(KeyEvent event) {
    if (event is! KeyDownEvent || autoDetectedTv) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select) {
      _switchToTv();
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      _arrowPresses++;
      if (_arrowPresses >= 3) _switchToTv();
    }
    return false;
  }

  static void _switchToTv() {
    debugPrint('DeviceProfile: 收到遥控器按键，识别为电视');
    _remoteTv = true;
    _apply();
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setBool(_remoteDetectedKey, true))
        .catchError((Object e) {
      debugPrint('保存遥控器识别记录失败: $e');
      return false;
    });
  }
}

/// 设置页"电视模式"：自动识别 / 强制电视界面 / 强制手机界面。
enum TvModeSetting {
  auto('自动'),
  on('开启'),
  off('关闭');

  const TvModeSetting(this.label);

  final String label;
}
