import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/api_config.dart';
import '../models/registered_device.dart';

/// 先补齐自有 API 的设备参数，再交给签名拦截器。
/// 使用普通拦截器，让同一个 Dio 发出的首次注册可以独立通过。
class DeviceRequestInterceptor extends Interceptor {
  DeviceRequestInterceptor({
    required Future<RegisteredDevice> Function() ensureDevice,
    required String baseUrl,
    Future<RegisteredDevice> Function()? ensureRegisteredDevice,
  })  : _ensureDevice = ensureDevice,
        _ensureRegisteredDevice = ensureRegisteredDevice ?? ensureDevice,
        _targetHost = Uri.parse(baseUrl).host;

  /// 一次视频解析沿用同一身份，避免注册完成时签名 URL 和请求身份错位。
  static const deviceSnapshotKey = 'shortplayDeviceSnapshot';

  final Future<RegisteredDevice> Function() _ensureDevice;
  final Future<RegisteredDevice> Function() _ensureRegisteredDevice;
  final String _targetHost;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final uri = options.uri;
    final path = uri.path.toLowerCase().replaceFirst(RegExp(r'/+$'), '');
    if ((uri.host.isNotEmpty && uri.host != _targetHost) ||
        path == ApiConfig.deviceRegister) {
      handler.next(options);
      return;
    }

    try {
      final cancelToken = options.cancelToken;
      final initialCancellation = cancelToken?.cancelError;
      if (initialCancellation != null) throw initialCancellation;
      final snapshot = options.extra[deviceSnapshotKey];
      final registration = path == ApiConfig.playbackReport
          ? _ensureRegisteredDevice()
          : snapshot is RegisteredDevice
              ? Future.value(snapshot)
              : _ensureDevice();
      final device = cancelToken == null
          ? await registration
          : await Future.any<RegisteredDevice>([
              registration,
              cancelToken.whenCancel.then<RegisteredDevice>((error) {
                throw error;
              }),
            ]);
      final cancellation = cancelToken?.cancelError;
      if (cancellation != null) throw cancellation;
      options.queryParameters = {
        ...options.queryParameters,
        'client_device': jsonEncode(device.toJson()),
      };
      handler.next(options);
    } catch (error, stackTrace) {
      if (error is DioException && CancelToken.isCancel(error)) {
        handler.reject(error);
        return;
      }
      handler.reject(DioException(
        requestOptions: options,
        error: error,
        stackTrace: stackTrace,
        message: error.toString(),
      ));
    }
  }
}
