import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_update.dart';
import 'api_client.dart';

/// 安卓手机和 TV 均在应用内下载并交给系统安装；iOS 打开更新链接。
class AppUpdateService extends ChangeNotifier {
  AppUpdateService(
      {required this.apiClient, Dio Function()? downloadClientFactory})
      : _downloadClientFactory = downloadClientFactory ?? Dio.new;

  static const _channel = MethodChannel('shortplay/update');
  final ApiClient apiClient;
  final Dio Function() _downloadClientFactory;

  bool get usesInAppUpdate =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
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

  Future<String> downloadApk(
    AppUpdate update, {
    required CancelToken cancelToken,
    required void Function(int received, int total) onProgress,
  }) async {
    final uri = Uri.tryParse(update.downloadUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ApiException('安装包下载地址无效');
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final directory = await _channel.invokeMethod<String>('updateDirectory');
    if (directory == null || directory.isEmpty) {
      throw ApiException('无法创建更新下载目录');
    }
    final folder = Directory(directory);
    await folder.create(recursive: true);
    // 每次下载独立文件，取消后立刻重试不会误删下一次下载的数据。
    final apk = File(
        '${folder.path}/update-${DateTime.now().microsecondsSinceEpoch}.apk');
    final partial = File('${apk.path}.part');
    final dio = _downloadClientFactory();
    dio.options.connectTimeout ??= const Duration(seconds: 30);
    try {
      await dio.download(
        update.downloadUrl,
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        options: Options(
            followRedirects: true,
            maxRedirects: 5,
            receiveTimeout: const Duration(seconds: 30),
            sendTimeout: const Duration(seconds: 30)),
      );
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if (!await partial.exists() || await partial.length() == 0) {
        throw ApiException('下载的安装包为空，请重试');
      }
      await partial.rename(apk.path);
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      return apk.path;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      if (await apk.exists()) await apk.delete();
      rethrow;
    } finally {
      dio.close(force: true);
    }
  }

  Future<bool> canInstallApks() async =>
      await _channel.invokeMethod<bool>('canInstallApks') ?? false;

  /// permission_required 表示已打开安装授权设置，返回 APP 后继续。
  Future<String> installApk(String path) async {
    final status =
        await _channel.invokeMethod<String>('installApk', {'path': path});
    if (status != 'permission_required' && status != 'installer_opened') {
      throw ApiException('无法打开系统安装界面');
    }
    return status!;
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
