import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      isTv = await _channel.invokeMethod<bool>('isTv') ?? false;
    } catch (e) {
      debugPrint('DeviceProfile.isTv 检测失败: $e');
    }
  }
}
