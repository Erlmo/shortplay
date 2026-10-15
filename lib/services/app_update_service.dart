import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_update.dart';
import 'api_client.dart';

/// 更新接口只提供链接，点击更新交给系统打开，不在应用内管理安装包。
class AppUpdateService extends ChangeNotifier {
  AppUpdateService({required this.apiClient});

  static const _channel = MethodChannel('shortplay/update');
  final ApiClient apiClient;
  AppUpdate? _requiredUpdate;

  AppUpdate? get requiredUpdate => _requiredUpdate;

  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<AppUpdate?> check({CancelToken? cancelToken}) async {
    if (!isSupported) throw ApiException('目前支持 iOS 和安卓设备检查更新');
    final info = await PackageInfo.fromPlatform();
    final version = info.version.trim();
    if (version.isEmpty) throw ApiException('无法读取当前版本，请稍后重试');
    final String device;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      device = 'ios';
    } else {
      final detected = await _channel.invokeMethod<String>('device');
      if (detected != 'android32' && detected != 'android64') {
        throw ApiException('无法识别设备架构，请重试');
      }
      device = detected!;
    }
    final update = await apiClient.checkAppUpdate(
        device: device, version: version, cancelToken: cancelToken);
    if (cancelToken?.isCancelled == true) return null;
    _requiredUpdate = update?.isRequired == true ? update : null;
    notifyListeners();
    return update;
  }

  Future<void> openUpdate(AppUpdate update) async {
    final opened = await _channel.invokeMethod<bool>('openUrl', {
      'url': update.downloadUrl,
    });
    if (opened != true) throw ApiException('无法打开更新链接，请稍后重试');
  }
}

String appUpdateError(Object error) {
  if (error is ApiException) return error.message;
  if (error is PlatformException) return error.message ?? '无法打开更新链接，请稍后重试';
  if (error is DioException) return '连接更新服务失败，请稍后重试';
  return '更新失败，请稍后重试';
}
