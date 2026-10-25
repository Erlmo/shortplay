import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/registered_device.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_registration_service.dart';

const _device = <String, String>{
  'device_id': '20916926365173371234567890123456',
  'install_id': '12021844138127631234567890123456',
  'cdid': 'c24da752-76d9-4cd0-9cff-2724f793dfdb',
  'device_brand': 'HONOR',
  'device_model': 'ABC-1234',
  'os_version': '12',
};

Map<String, dynamic> _homeResponse(RequestOptions request) => {
      'code': 0,
      'data': {
        'offset': int.tryParse('${request.queryParameters['offset']}') ?? 0,
        'session_id': 'device-session',
        'has_more': true,
        'next_offset': 20,
        'list': [],
      },
    };

class _Backend {
  _Backend(this.respond);

  final FutureOr<Map<String, dynamic>> Function(RequestOptions) respond;
  final List<RequestOptions> requests = [];

  void attach(Dio dio) {
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        requests.add(options);
        try {
          final response = await respond(options);
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: response,
          ));
        } catch (error) {
          handler.reject(DioException(
            requestOptions: options,
            error: error,
            type: DioExceptionType.connectionError,
          ));
        }
      },
    ));
  }
}

ApiClient _client(_Backend backend) {
  final client = ApiClient(baseUrl: 'https://device.test:8443');
  backend.attach(client.dio);
  addTearDown(client.dispose);
  return client;
}

Map<String, dynamic> _requestDevice(RequestOptions request) =>
    jsonDecode(request.queryParameters['client_device'] as String)
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('启动预注册和并发首页共享注册，完成后首屏和翻页复用同一长ID', () async {
    final started = Completer<void>();
    final finishRegistration = Completer<Map<String, dynamic>>();
    final backend = _Backend((request) {
      if (request.path == '/device/register') {
        started.complete();
        return finishRegistration.future;
      }
      return _homeResponse(request);
    });
    final client = _client(backend);
    final initialization = client.initializeDevice();
    final firstPage = client.fetchHomePage();
    final concurrentPage = client.fetchHomePage();

    await started.future;
    expect(
        backend.requests.map((request) => request.path), ['/device/register']);
    final registration = backend.requests.single;
    expect(registration.method, 'POST');
    expect(registration.data, isNull);
    expect(registration.queryParameters, isEmpty);
    finishRegistration.complete({
      'code': 0,
      'data': {..._device, 'version_name': '6.2.3.32'},
    });
    await initialization;
    await Future.wait([firstPage, concurrentPage]);
    final page =
        await client.fetchHomePage(offset: 20, sessionId: 'device-session');

    expect(page.sessionId, 'device-session');
    expect(page.offset, 20);
    expect(backend.requests.where((r) => r.path == '/device/register'),
        hasLength(1));
    final homeRequests =
        backend.requests.where((r) => r.path == '/nove/home').toList();
    expect(homeRequests, hasLength(3));
    for (final request in backend.requests) {
      expect(request.uri.origin, 'https://device.test:8443');
    }
    for (final request in homeRequests) {
      expect(_requestDevice(request), _device);
      expect(request.data, isNull);
    }
    expect(homeRequests.first.queryParameters.keys, ['client_device']);
    expect(homeRequests.last.queryParameters, {
      'client_device': jsonEncode(_device),
      'offset': '20',
      'session_id': 'device-session',
    });
  });

  test('重建客户端模拟重启，从本地复用设备而不重新注册', () async {
    final firstBackend = _Backend((request) =>
        request.path == '/device/register'
            ? {'code': 0, 'data': _device}
            : _homeResponse(request));
    await _client(firstBackend).fetchHomePage();

    final restartedBackend = _Backend(_homeResponse);
    await _client(restartedBackend).fetchHomePage();
    expect(restartedBackend.requests.map((r) => r.path), ['/nove/home']);
    expect(_requestDevice(restartedBackend.requests.single), _device);
  });

  test('首页公告和TV扫码同时请求时共用一次注册，不出现注册递归', () async {
    final started = Completer<void>();
    final registration = Completer<Map<String, dynamic>>();
    final backend = _Backend((request) {
      if (request.path == '/device/register') {
        started.complete();
        return registration.future;
      }
      return _homeResponse(request);
    });
    final client = _client(backend);
    final initialization = client.initializeDevice();
    final home = client.fetchHomePage();
    final notice = client.dio.get('/notice');
    final tvLink = client.dio.post('/tvlink/create');
    await started.future;
    expect(
        backend.requests.map((request) => request.path), ['/device/register']);
    registration.complete({'code': 0, 'data': _device});
    await Future.wait<Object?>([initialization, home, notice, tvLink]);

    expect(
        backend.requests.where((request) => request.path == '/device/register'),
        hasLength(1));
    expect(backend.requests.skip(1).map((request) => request.path),
        unorderedEquals(['/nove/home', '/notice', '/tvlink/create']));
    for (final request in backend.requests.skip(1)) {
      expect(_requestDevice(request), _device);
    }
  });

  test('另一次安装拥有独立设备身份，不复用之前安装的内存身份', () async {
    final firstBackend = _Backend((request) =>
        request.path == '/device/register'
            ? {'code': 0, 'data': _device}
            : _homeResponse(request));
    await _client(firstBackend).fetchHomePage();

    SharedPreferences.setMockInitialValues({});
    final secondDevice = {
      ..._device,
      'device_id': '3091692636517337',
      'install_id': '2202184413812763'
    };
    final secondBackend = _Backend((request) =>
        request.path == '/device/register'
            ? {'code': 0, 'data': secondDevice}
            : _homeResponse(request));
    await _client(secondBackend).fetchHomePage();
    expect(secondBackend.requests.map((r) => r.path),
        ['/device/register', '/nove/home']);
    expect(_requestDevice(secondBackend.requests.last), secondDevice);
    expect(_requestDevice(firstBackend.requests.last), _device);
  });

  test('首次注册失败仍用默认设备请求首页，默认身份不保存为个人设备', () async {
    var attempts = 0;
    final backend = _Backend((request) {
      if (request.path == '/device/register') {
        attempts++;
        throw StateError('offline');
      }
      return _homeResponse(request);
    });
    final client = _client(backend);
    final page = await client.fetchHomePage();
    expect(page.sessionId, 'device-session');
    expect(backend.requests.map((r) => r.path),
        ['/device/register', '/nove/home']);
    expect(_requestDevice(backend.requests.last),
        RegisteredDevice.defaultDevice.toJson());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(DeviceRegistrationService.storageKey), isFalse);

    await client.fetchHomePage();
    expect(attempts, 1);
    expect(_requestDevice(backend.requests.last),
        RegisteredDevice.defaultDevice.toJson());
  });

  for (final invalidData in <Object?>[
    [],
    null,
    {..._device, 'device_id': 2091692636517337},
    {..._device, 'cdid': 'invalid'},
  ]) {
    test(
        '注册信息无效时仍使用默认设备加载首页：${invalidData.runtimeType} ${invalidData is Map ? invalidData['device_id'] : ''}',
        () async {
      final backend = _Backend((request) => request.path == '/device/register'
          ? {'code': 0, 'data': invalidData}
          : _homeResponse(request));
      await _client(backend).fetchHomePage();
      expect(backend.requests.map((r) => r.path),
          ['/device/register', '/nove/home']);
      expect(_requestDevice(backend.requests.last),
          RegisteredDevice.defaultDevice.toJson());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(DeviceRegistrationService.storageKey), isFalse);
    });
  }

  test('注册接口业务错误不阻塞初始化，首页先通过默认设备加载', () async {
    var attempts = 0;
    final backend = _Backend((request) {
      if (request.path == '/device/register') {
        attempts++;
        return {'code': 502, 'message': '注册暂不可用'};
      }
      return _homeResponse(request);
    });
    final client = _client(backend);
    await client.initializeDevice();
    await client.fetchHomePage();
    expect(attempts, 1);
    expect(_requestDevice(backend.requests.last),
        RegisteredDevice.defaultDevice.toJson());
  });

  test('缓存损坏时先重新注册，注入Dio的自定义域名和端口保持生效', () async {
    SharedPreferences.setMockInitialValues({
      DeviceRegistrationService.storageKey: '{broken',
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8765'));
    final client = ApiClient(dio: dio);
    addTearDown(client.dispose);
    final backend = _Backend((request) => request.path == '/device/register'
        ? {'code': 0, 'data': _device}
        : _homeResponse(request));
    backend.attach(dio);
    await client.fetchHomePage();
    expect(backend.requests.map((r) => r.path),
        ['/device/register', '/nove/home']);
    expect(
        backend.requests.every((r) => r.uri.origin == 'http://localhost:8765'),
        isTrue);
    expect(_requestDevice(backend.requests.last), _device);
  });

  test('更新和搜索请求也先完成注册，并统一使用同一设备信息', () async {
    final backend = _Backend((request) {
      if (request.path == '/device/register') {
        return {'code': 0, 'data': _device};
      }
      return {
        'code': 0,
        'data': request.path == '/update/check'
            ? {'update_available': false}
            : {'query': '万妖', 'items': []},
      };
    });
    final client = _client(backend);
    expect(await client.checkAppUpdate(device: 'android64', version: '3.2.2'),
        isNull);
    await client.fetchSearchSuggestions('万妖');

    expect(backend.requests.map((r) => r.path),
        ['/device/register', '/update/check', '/nove/search/suggest']);
    expect(backend.requests.first.queryParameters, isEmpty);
    for (final request in backend.requests.skip(1)) {
      expect(_requestDevice(request), _device);
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(DeviceRegistrationService.storageKey), isTrue);
  });
}
