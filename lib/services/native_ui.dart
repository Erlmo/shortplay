import 'dart:io';

import 'package:flutter/services.dart';

class NativeUi {
  static const MethodChannel _channel = MethodChannel('com.shortplay/ui');

  /// 播放页底部系统条自动隐藏（红果同款）：
  /// - iOS：Home 指示条（白条）自动隐藏，手指碰到底部或上滑时系统自动显示；
  /// - Android：隐藏导航栏/手势条，从底部上滑临时显示，几秒后自动收起。
  static Future<void> setBottomBarAutoHidden(bool hidden) async {
    try {
      if (Platform.isIOS) {
        await _channel
            .invokeMethod('setHomeIndicatorHidden', {'hidden': hidden});
      } else if (Platform.isAndroid) {
        await _channel
            .invokeMethod('setNavigationBarAutoHidden', {'hidden': hidden});
      }
    } catch (_) {
      // 未实现的平台静默忽略
    }
  }
}
