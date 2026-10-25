import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shortplay/models/registered_device.dart';
import 'package:shortplay/services/device_registration_service.dart';

Map<String, dynamic> _registration({String deviceId = '2091692636517337'}) => {
      'device_id': deviceId,
      'install_id': '1202184413812763',
      'cdid': 'c24da752-76d9-4cd0-9cff-2724f793dfdb',
      'device_brand': 'HONOR',
      'device_model': 'AB1-CD23',
      'os_version': '12',
      'version_code': '62332',
    };

class _FailingWritePreferences implements SharedPreferences {
  _FailingWritePreferences(this.delegate);

  final SharedPreferences delegate;
  bool rejectWrites = true;

  @override
  Object? get(String key) => delegate.get(key);

  @override
  Future<bool> setString(String key, String value) async {
    final saved = await delegate.setString(key, value);
    return !rejectWrites && saved;
  }

  @override
  Future<bool> remove(String key) => delegate.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('首次注册保存完整身份，重启新实例直接复用且不保存额外业务字段', () async {
    var registrations = 0;
    final first = DeviceRegistrationService(registerDevice: () async {
      registrations++;
      return _registration();
    });

    final device = await first.ensureRegistered();
    expect(registrations, 1);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(
      prefs.getString(DeviceRegistrationService.storageKey)!,
    );
    expect(saved, device.toJson());
    expect(saved, isNot(contains('version_code')));

    final restarted = DeviceRegistrationService(registerDevice: () async {
      registrations++;
      throw StateError('本地已有身份不应再次注册');
    });
    expect((await restarted.ensureRegistered()).toJson(), device.toJson());
    expect(identical(await first.ensureRegistered(), device), isTrue);
    expect(registrations, 1);
  });

  test('启动和多个首页请求并发时只注册一次', () async {
    final response = Completer<Map<String, dynamic>>();
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () {
      registrations++;
      return response.future;
    });

    final first = service.ensureRegistered();
    final second = service.ensureRegistered();
    final third = service.ensureRegistered();
    expect(identical(first, second), isTrue);
    expect(identical(first, third), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(registrations, 1);
    response.complete(_registration());
    final devices = await Future.wait([first, second, third]);
    expect(devices.every((device) => identical(device, devices.first)), isTrue);
    expect(registrations, 1);
  });

  test('网络注册失败不缓存，之后重试能够成功', () async {
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () async {
      registrations++;
      if (registrations == 1) throw TimeoutException('离线');
      return _registration();
    });

    await expectLater(
      service.ensureRegistered(),
      throwsA(isA<DeviceRegistrationException>().having(
        (error) => error.cause,
        '原始错误',
        isA<TimeoutException>(),
      )),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(DeviceRegistrationService.storageKey), isFalse);
    expect((await service.ensureRegistered()).deviceId, '2091692636517337');
    expect(registrations, 2);
  });

  test('读本地存储失败不注册，存储恢复后能够重试', () async {
    var loads = 0;
    var registrations = 0;
    final service = DeviceRegistrationService(
      registerDevice: () async {
        registrations++;
        return _registration();
      },
      preferencesLoader: () async {
        loads++;
        if (loads == 1) throw StateError('读取失败');
        return SharedPreferences.getInstance();
      },
    );

    await expectLater(
      service.ensureRegistered(),
      throwsA(isA<DeviceRegistrationException>()),
    );
    expect(registrations, 0);
    await service.ensureRegistered();
    expect(loads, 2);
    expect(registrations, 1);
  });

  testWidgets('首次失败先返回默认设备，不写入独立身份缓存，后续读取立即兜底', (tester) async {
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () async {
      registrations++;
      throw TimeoutException('注册不可用');
    });
    addTearDown(service.dispose);

    final device = await service.ensureRequestDevice();
    expect(device, same(RegisteredDevice.defaultDevice));
    expect(service.isUsingDefaultDevice, isTrue);
    expect(await service.readCachedDevice(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(DeviceRegistrationService.storageKey), isFalse);
    expect(await service.ensureRequestDevice(), same(device));
    expect(registrations, 1);

    // 严格接口供写入使用，不能把公共设备当成注册成功。
    await expectLater(service.ensureRegistered(),
        throwsA(isA<DeviceRegistrationException>()));
    expect(service.isUsingDefaultDevice, isTrue);
    service.dispose();
  });

  testWidgets('慢注册超过首屏预算后先兜底，晚到成功只注册一次并切换刷新', (tester) async {
    final response = Completer<Map<String, dynamic>>();
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () {
      registrations++;
      return response.future;
    });
    addTearDown(service.dispose);
    var switches = 0;
    service.addListener(() => switches++);

    RegisteredDevice? first;
    unawaited(service.ensureRequestDevice().then((value) => first = value));
    await tester.pump();
    expect(first, isNull);
    await tester.pump(const Duration(seconds: 3));
    expect(first, same(RegisteredDevice.defaultDevice));
    expect(await service.ensureRequestDevice(), same(first));
    expect(registrations, 1);
    expect(switches, 0);
    response.complete(_registration());
    await tester.pump();

    expect(service.isUsingDefaultDevice, isFalse);
    expect((await service.ensureRequestDevice()).deviceId, '2091692636517337');
    expect((await service.readCachedDevice())?.deviceId, '2091692636517337');
    expect(switches, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(registrations, 1);
    expect(switches, 1);
  });

  testWidgets('失败后台按5到60秒退避，读取不触发重复注册，成功后停止', (tester) async {
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () async {
      registrations++;
      if (registrations < 7) throw TimeoutException('尚未恢复');
      return _registration();
    });
    addTearDown(service.dispose);
    var switches = 0;
    service.addListener(() => switches++);
    await service.ensureRequestDevice();
    expect(registrations, 1);
    for (final seconds in [5, 10, 20, 40, 60, 60]) {
      final before = registrations;
      expect(await service.ensureRequestDevice(),
          same(RegisteredDevice.defaultDevice));
      await tester.pump(Duration(seconds: seconds - 1));
      expect(registrations, before);
      await tester.pump(const Duration(seconds: 1));
      expect(registrations, before + 1);
    }
    expect(service.isUsingDefaultDevice, isFalse);
    expect(switches, 1);
    await tester.pump(const Duration(minutes: 3));
    expect(registrations, 7);
  });

  testWidgets('首轮超时后迟到失败保持兜底，定时任务与在途注册共享一次请求', (tester) async {
    final response = Completer<Map<String, dynamic>>();
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () {
      registrations++;
      if (registrations == 1) return response.future;
      return Future.value(_registration());
    });
    addTearDown(service.dispose);
    unawaited(service.ensureRequestDevice());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 5));
    expect(registrations, 1);
    expect(service.isUsingDefaultDevice, isTrue);
    expect(await service.ensureRequestDevice(),
        same(RegisteredDevice.defaultDevice));
    response.completeError(TimeoutException('迟到的失败'));
    await tester.pump();
    expect(registrations, 1);
    await tester.pump(const Duration(seconds: 9));
    expect(registrations, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(registrations, 2);
    expect(service.isUsingDefaultDevice, isFalse);
  });

  testWidgets('恢复前台立即重试，多个重试仍然单飞', (tester) async {
    final response = Completer<Map<String, dynamic>>();
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () {
      registrations++;
      if (registrations == 1) throw TimeoutException('首次失败');
      return response.future;
    });
    addTearDown(service.dispose);
    await service.ensureRequestDevice();
    final first = service.retryRegistration();
    final second = service.retryRegistration();
    await tester.pump();
    expect(registrations, 2);
    expect(await service.ensureRequestDevice(),
        same(RegisteredDevice.defaultDevice));
    response.complete(_registration());
    await Future.wait([first, second]);
    expect(service.isUsingDefaultDevice, isFalse);
  });

  testWidgets('兜底读取本地缓存失败后，存储恢复可以后台注册', (tester) async {
    var loads = 0;
    var registrations = 0;
    final service = DeviceRegistrationService(
      registerDevice: () async {
        registrations++;
        return _registration();
      },
      preferencesLoader: () async {
        if (++loads == 1) throw StateError('存储暂不可用');
        return SharedPreferences.getInstance();
      },
    );
    addTearDown(service.dispose);
    expect(await service.ensureRequestDevice(),
        same(RegisteredDevice.defaultDevice));
    expect(registrations, 0);
    await tester.pump(const Duration(seconds: 5));
    expect(registrations, 1);
    expect(service.isUsingDefaultDevice, isFalse);
  });

  testWidgets('身份保存失败时仍用默认设备，恢复保存后才能切换', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final failingPrefs = _FailingWritePreferences(prefs);
    final service = DeviceRegistrationService(
      registerDevice: () async => _registration(),
      preferencesLoader: () async => failingPrefs,
    );
    addTearDown(service.dispose);
    var switches = 0;
    service.addListener(() => switches++);
    expect(await service.ensureRequestDevice(),
        same(RegisteredDevice.defaultDevice));
    expect(prefs.containsKey(DeviceRegistrationService.storageKey), isFalse);
    expect(switches, 0);
    failingPrefs.rejectWrites = false;
    await tester.pump(const Duration(seconds: 5));
    expect(service.isUsingDefaultDevice, isFalse);
    expect(switches, 1);
    expect(prefs.containsKey(DeviceRegistrationService.storageKey), isTrue);
  });

  testWidgets('已有有效身份直接读取，不注册且不通知兜底切换', (tester) async {
    SharedPreferences.setMockInitialValues({
      DeviceRegistrationService.storageKey: jsonEncode(_registration()),
    });
    var switches = 0;
    final service = DeviceRegistrationService(registerDevice: () async {
      fail('本地有效身份不应发起注册');
    });
    addTearDown(service.dispose);
    service.addListener(() => switches++);
    expect((await service.ensureRequestDevice()).deviceId, '2091692636517337');
    expect(service.isUsingDefaultDevice, isFalse);
    expect(switches, 0);
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets('关闭服务取消后台重试', (tester) async {
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () async {
      registrations++;
      throw TimeoutException('失败');
    });
    await service.ensureRequestDevice();
    service.dispose();
    await tester.pump(const Duration(minutes: 3));
    await service.retryRegistration();
    expect(registrations, 1);
  });

  testWidgets('关闭服务后在途成功保存身份供下次复用，但不发通知或继续重试', (tester) async {
    final response = Completer<Map<String, dynamic>>();
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () {
      registrations++;
      return response.future;
    });
    var switches = 0;
    service.addListener(() => switches++);
    unawaited(service.ensureRequestDevice());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    service.dispose();
    response.complete(_registration());
    await tester.pump();
    await tester.pump(const Duration(minutes: 3));
    expect(switches, 0);
    expect(registrations, 1);
    final restarted = DeviceRegistrationService(registerDevice: () async {
      fail('已经保存身份，不应重新注册');
    });
    addTearDown(restarted.dispose);
    expect((await restarted.ensureRegistered()).deviceId, '2091692636517337');
  });

  for (final invalidCache in <Object>[
    '{invalid-json',
    '[]',
    '{}',
    jsonEncode({..._registration(), 'device_id': '0'}),
    123,
  ]) {
    test('损坏设备缓存重新注册: $invalidCache', () async {
      SharedPreferences.setMockInitialValues({
        DeviceRegistrationService.storageKey: invalidCache,
      });
      var registrations = 0;
      final service = DeviceRegistrationService(registerDevice: () async {
        registrations++;
        return _registration();
      });

      final device = await service.ensureRegistered();
      expect(registrations, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString(DeviceRegistrationService.storageKey)!),
        device.toJson(),
      );
    });
  }

  test('无效注册响应不会持久化，修复响应后可以重新注册', () async {
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () async {
      registrations++;
      return registrations == 1 ? {'device_id': '123'} : _registration();
    });

    await expectLater(
      service.ensureRegistered(),
      throwsA(isA<DeviceRegistrationException>().having(
        (error) => error.cause,
        '格式错误',
        isA<FormatException>(),
      )),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(DeviceRegistrationService.storageKey), isFalse);
    await service.ensureRegistered();
    expect(registrations, 2);
  });

  test('保存失败清理提前更新的内存缓存，不使用未保存的身份', () async {
    final prefs = await SharedPreferences.getInstance();
    final failingPrefs = _FailingWritePreferences(prefs);
    final service = DeviceRegistrationService(
      registerDevice: () async => _registration(deviceId: '111'),
      preferencesLoader: () async => failingPrefs,
    );

    await expectLater(
      service.ensureRegistered(),
      throwsA(isA<DeviceRegistrationException>()),
    );
    expect(prefs.containsKey(DeviceRegistrationService.storageKey), isFalse);

    final restarted = DeviceRegistrationService(
      registerDevice: () async => _registration(deviceId: '222'),
    );
    expect((await restarted.ensureRegistered()).deviceId, '222');
    failingPrefs.rejectWrites = false;
    expect((await service.ensureRegistered()).deviceId, '222');
  });

  test('长设备ID按字符串完整保存，包含小数系统版本时可以复用', () async {
    const longId = '12345678901234567890123456789012';
    final service = DeviceRegistrationService(
        registerDevice: () async => {
              ..._registration(deviceId: longId),
              'install_id': longId,
              'os_version': '12.0.1',
            });

    final device = await service.ensureRegistered();
    expect(device.deviceId, longId);
    expect(device.installId, longId);
    final restarted = DeviceRegistrationService(registerDevice: () async => {});
    expect((await restarted.ensureRegistered()).toJson(), device.toJson());
  });

  final invalidFields = <({String key, Object? value})>[
    (key: 'device_id', value: 2091692636517337),
    (key: 'device_id', value: '0'),
    (key: 'device_id', value: '0123'),
    (key: 'device_id', value: '-1'),
    (key: 'device_id', value: '123\n'),
    (key: 'device_id', value: '123456789012345678901234567890123'),
    (key: 'install_id', value: null),
    (key: 'cdid', value: 'invalid-uuid'),
    (key: 'device_brand', value: ' '),
    (key: 'device_model', value: 'model\r\nInjected: true'),
    (key: 'device_model', value: List.filled(65, 'a').join()),
    (key: 'os_version', value: '12..0'),
    (key: 'os_version', value: 'Android 12'),
    (key: 'os_version', value: '12345678901234567'),
  ];
  for (final field in invalidFields) {
    test('拒绝非法身份字段 ${field.key}=${field.value}', () {
      expect(
        () => RegisteredDevice.fromJson({
          ..._registration(),
          field.key: field.value,
        }),
        throwsFormatException,
      );
    });
  }
}
