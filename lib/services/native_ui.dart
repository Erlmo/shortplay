import 'dart:io';

import 'package:flutter/services.dart';

class NativeUi {
  static const MethodChannel _channel = MethodChannel('com.shortplay/ui');

  // iOS: 隐藏或显示 Home 指示条
  static Future<void> setHomeIndicatorHidden(bool hidden) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setHomeIndicatorHidden', {'hidden': hidden});
    } catch (_) {
      // 在非 iOS 或未实现时静默忽略
    }
  }
}
