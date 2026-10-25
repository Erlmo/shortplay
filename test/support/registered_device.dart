import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/services/device_registration_service.dart';

/// 无关业务测试使用已完成注册的安装，设备注册专项测试自行清空存储。
const testRegisteredDevice = <String, String>{
  'device_id': '2091692636517337',
  'install_id': '1202184413812763',
  'cdid': 'c24da752-76d9-4cd0-9cff-2724f793dfdb',
  'device_brand': 'HONOR',
  'device_model': 'TEST-DEVICE',
  'os_version': '12',
};

String get testRegisteredDeviceJson => jsonEncode(testRegisteredDevice);

Map<String, Object> registeredDevicePreferences([
  Map<String, Object> values = const {},
]) =>
    {
      ...values,
      DeviceRegistrationService.storageKey: testRegisteredDeviceJson,
    };

void seedRegisteredDevice([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(registeredDevicePreferences(values));
}
