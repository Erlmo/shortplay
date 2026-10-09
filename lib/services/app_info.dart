import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

Future<String> loadAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final version = info.version.trim();
    final buildNumber = info.buildNumber.trim();
    if (version.isEmpty) {
      return '暂不可用';
    }
    return buildNumber.isEmpty ? version : '$version+$buildNumber';
  } catch (error) {
    debugPrint('读取应用版本失败: $error');
    return '暂不可用';
  }
}
