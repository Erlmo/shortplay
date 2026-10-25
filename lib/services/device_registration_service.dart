import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/registered_device.dart';

class DeviceRegistrationException implements Exception {
  const DeviceRegistrationException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// 同一个实例内的启动注册和所有业务请求共享一次注册任务。
/// 只在本地保存成功后才使用新身份，重启和应用升级均复用已保存的身份。
class DeviceRegistrationService extends ChangeNotifier {
  DeviceRegistrationService({
    required Future<Map<String, dynamic>> Function() registerDevice,
    Future<SharedPreferences> Function()? preferencesLoader,
    this.requestWaitTimeout = const Duration(seconds: 3),
  })  : _registerDevice = registerDevice,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String storageKey = 'home_registered_device_v1';

  final Future<Map<String, dynamic>> Function() _registerDevice;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final Duration requestWaitTimeout;

  RegisteredDevice? _device;
  Future<RegisteredDevice>? _pending;
  Timer? _retryTimer;
  int _retryAttempt = 0;
  bool _usingDefaultDevice = false;
  bool _disposed = false;

  bool get isUsingDefaultDevice => _usingDefaultDevice;

  /// 读取内容可以临时使用公共设备，首次失败后不会让每个请求再等待注册。
  /// 只有独立身份持久化成功，才结束兜底并通知首页刷新。
  Future<RegisteredDevice> ensureRequestDevice() async {
    _checkNotDisposed();
    if (_device != null) return _device!;
    if (_usingDefaultDevice) return RegisteredDevice.defaultDevice;
    try {
      // 首屏只等待短预算；超时不取消真正的注册，晚到的成功仍可切换身份。
      return await ensureRegistered().timeout(requestWaitTimeout);
    } catch (_) {
      _checkNotDisposed();
      // 另一个等待同一失败任务的请求可能已重试成功。
      if (_device != null) return _device!;
      _usingDefaultDevice = true;
      _scheduleRetry();
      return RegisteredDevice.defaultDevice;
    }
  }

  Future<RegisteredDevice> ensureRegistered() {
    if (_disposed) {
      return Future.error(const DeviceRegistrationException('设备服务已关闭'));
    }
    final device = _device;
    if (device != null) return Future.value(device);
    return _pending ??= _loadOrRegister();
  }

  /// 前台恢复时可提前重试；定时重试与其他注册请求仍共享同一任务。
  /// 失败保持兜底，并继续按 5、10、20、40、60 秒退避。
  Future<void> retryRegistration() async {
    if (_disposed || !_usingDefaultDevice || _device != null) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    try {
      await ensureRegistered();
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_disposed ||
        !_usingDefaultDevice ||
        _device != null ||
        _retryTimer != null) {
      return;
    }
    const seconds = [5, 10, 20, 40, 60];
    final index = _retryAttempt.clamp(0, seconds.length - 1);
    _retryAttempt++;
    _retryTimer = Timer(Duration(seconds: seconds[index]), () {
      _retryTimer = null;
      unawaited(retryRegistration());
    });
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw const DeviceRegistrationException('设备服务已关闭');
    }
  }

  RegisteredDevice _acceptDevice(RegisteredDevice device) {
    _checkNotDisposed();
    final wasUsingDefault = _usingDefaultDevice;
    _device = device;
    _usingDefaultDevice = false;
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (wasUsingDefault) notifyListeners();
    return device;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    super.dispose();
  }

  /// 离线观看排队时只读取已有身份，不因保存观看进度发起网络注册。
  Future<RegisteredDevice?> readCachedDevice() async {
    if (_device != null) return _device;
    final prefs = await _loadPreferences();
    final cached = prefs.get(storageKey);
    if (cached is! String) return null;
    try {
      final json = jsonDecode(cached);
      return json is Map<String, dynamic>
          ? RegisteredDevice.fromJson(json)
          : null;
    } on FormatException {
      return null;
    }
  }

  Future<RegisteredDevice> _loadOrRegister() async {
    try {
      final prefs = await _loadPreferences();
      final cached = prefs.get(storageKey);
      if (cached != null) {
        try {
          if (cached is! String) throw const FormatException('设备缓存类型无效');
          final decoded = jsonDecode(cached);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('设备缓存格式无效');
          }
          final device = RegisteredDevice.fromJson(decoded);
          return _acceptDevice(device);
        } on FormatException {
          // 不使用损坏或不完整的身份发送业务请求。
          await _removeInvalidCache(prefs);
        }
      }

      final response = await _requestRegistration();
      late final RegisteredDevice device;
      try {
        device = RegisteredDevice.fromJson(response);
      } on FormatException catch (error) {
        throw DeviceRegistrationException(
          '设备注册信息无效，请稍后重试',
          cause: error,
        );
      }
      await _saveDevice(prefs, device);
      return _acceptDevice(device);
    } finally {
      // 注册或持久化失败后，下次业务请求可以重新注册。
      _pending = null;
    }
  }

  Future<SharedPreferences> _loadPreferences() async {
    try {
      return await _preferencesLoader();
    } catch (error) {
      throw DeviceRegistrationException('读取本地设备信息失败，请重试', cause: error);
    }
  }

  Future<Map<String, dynamic>> _requestRegistration() async {
    try {
      return await _registerDevice();
    } catch (error) {
      throw DeviceRegistrationException('设备注册失败，请检查网络后重试', cause: error);
    }
  }

  Future<void> _removeInvalidCache(SharedPreferences prefs) async {
    try {
      if (!await prefs.remove(storageKey)) {
        throw const DeviceRegistrationException('清理设备缓存失败，请重试');
      }
    } on DeviceRegistrationException {
      rethrow;
    } catch (error) {
      throw DeviceRegistrationException('清理设备缓存失败，请重试', cause: error);
    }
  }

  Future<void> _saveDevice(
    SharedPreferences prefs,
    RegisteredDevice device,
  ) async {
    try {
      if (!await prefs.setString(storageKey, jsonEncode(device.toJson()))) {
        throw const DeviceRegistrationException('保存设备信息失败，请重试');
      }
    } catch (error) {
      // SharedPreferences 在写入平台之前会更新内存缓存；写入失败时清掉它，
      // 避免另一个服务实例误把未持久化的身份当作注册成功。
      try {
        await prefs.remove(storageKey);
      } catch (_) {
        // 保留原始保存错误，让首页显示可重试的错误状态。
      }
      if (error is DeviceRegistrationException) rethrow;
      throw DeviceRegistrationException('保存设备信息失败，请重试', cause: error);
    }
  }
}
