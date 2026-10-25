import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/models/registered_device.dart';
import 'package:shortplay/services/device_request_interceptor.dart';

import 'support/registered_device.dart';

Dio _client(Future<RegisteredDevice> Function() ensureDevice,
    List<RequestOptions> requests,
    {void Function(RequestOptions)? beforeTransport}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test:8443'));
  dio.interceptors.add(DeviceRequestInterceptor(
    ensureDevice: ensureDevice,
    baseUrl: dio.options.baseUrl,
  ));
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    beforeTransport?.call(options);
    requests.add(options);
    handler.resolve(Response(
      requestOptions: options,
      statusCode: 200,
      data: {'code': 0},
    ));
  }));
  addTearDown(() => dio.close(force: true));
  return dio;
}

RegisteredDevice _device() => RegisteredDevice.fromJson(testRegisteredDevice);

void main() {
  test('视频签名沿用内部身份快照，公共设备快照不能绕过观看上报校验', () async {
    final requests = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
    dio.interceptors.add(DeviceRequestInterceptor(
      ensureDevice: () async => _device(),
      ensureRegisteredDevice: () async => throw StateError('尚未注册'),
      baseUrl: dio.options.baseUrl,
    ));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      handler.resolve(Response(requestOptions: options, statusCode: 200));
    }));
    addTearDown(() => dio.close(force: true));
    final options = Options(extra: {
      DeviceRequestInterceptor.deviceSnapshotKey:
          RegisteredDevice.defaultDevice,
    });
    await dio.post('/algorithm/sign', options: options);
    expect(jsonDecode(requests.single.queryParameters['client_device']),
        RegisteredDevice.defaultDevice.toJson());
    await expectLater(dio.post('/nove/playback/report', options: options),
        throwsA(isA<DioException>()));
    expect(requests, hasLength(1));
  });

  test('所有自有GET和POST接口在后续签名拦截器前携带同一设备', () async {
    final requests = <RequestOptions>[];
    final signedUris = <Uri>[];
    final dio = _client(() async => _device(), requests,
        beforeTransport: (options) => signedUris.add(options.uri));
    final paths = <String, String>{
      '/nove/home': 'GET',
      '/nove/rank': 'GET',
      '/nove/directory': 'GET',
      '/nove/seasons': 'GET',
      '/nove/danmaku': 'GET',
      '/nove/search': 'GET',
      '/nove/search/suggest': 'GET',
      '/nove/search/season': 'GET',
      '/nove/share': 'POST',
      '/notice': 'GET',
      '/update/check': 'GET',
      '/tvlink/create': 'POST',
      '/tvlink/status': 'POST',
      '/tvlink/acknowledge': 'POST',
      '/tvlink/cancel': 'POST',
      '/algorithm/sign': 'POST',
      '/algorithm/spade': 'POST',
      '/device/status': 'GET',
    };
    for (final entry in paths.entries) {
      await dio.request<Map<String, dynamic>>(
        entry.key,
        queryParameters: {'business': ' +/%中文 '},
        data: entry.value == 'POST' ? {'payload': 'body不变'} : null,
        options: Options(method: entry.value),
      );
    }

    expect(requests, hasLength(paths.length));
    expect(signedUris, requests.map((request) => request.uri));
    for (final request in requests) {
      expect(request.queryParameters, {
        'business': ' +/%中文 ',
        'client_device': testRegisteredDeviceJson,
      });
      expect(jsonDecode(request.uri.queryParameters['client_device']!),
          testRegisteredDevice);
      if (request.method == 'POST') {
        expect(request.data, {'payload': 'body不变'});
      }
    }
  });

  test('首次注册引导请求不等待身份，不注入设备也不递归', () async {
    var preparations = 0;
    final requests = <RequestOptions>[];
    final dio = _client(() {
      preparations++;
      return Completer<RegisteredDevice>().future;
    }, requests);
    await dio.post('/device/register');
    expect(preparations, 0);
    expect(requests.single.queryParameters, isEmpty);
  });

  test('外部视频和CDN请求保持原有URI及参数，完全不准备设备', () async {
    var preparations = 0;
    final requests = <RequestOptions>[];
    final dio = _client(() async {
      preparations++;
      return _device();
    }, requests);
    for (final url in [
      'https://api3-normal-sinfonlinea.fqnovel.com/novel/player/video_model/v1/?device_id=123&iid=456&signature=%2B%2F',
      'https://video.example/v.mp4?signature=%2B%2F&expires=123',
    ]) {
      await dio.getUri(Uri.parse(url));
      expect(requests.last.uri.toString(), url);
      expect(requests.last.queryParameters, isNot(contains('client_device')));
    }
    expect(preparations, 0);
  });

  test('请求不能用陈旧client_device覆盖当前安装身份', () async {
    final requests = <RequestOptions>[];
    final dio = _client(() async => _device(), requests);
    await dio.get('/nove/home',
        queryParameters: {'client_device': '{"device_id":"old"}'});
    expect(requests.single.queryParameters,
        {'client_device': testRegisteredDeviceJson});
  });

  test('等待注册时取消单个请求立即退出，其它请求仍可等待同一身份', () async {
    final gate = Completer<RegisteredDevice>();
    final started = Completer<void>();
    final requests = <RequestOptions>[];
    final dio = _client(() {
      if (!started.isCompleted) started.complete();
      return gate.future;
    }, requests);
    final token = CancelToken();
    final canceled = dio.get('/nove/search', cancelToken: token);
    final cancelExpectation = expectLater(
      canceled,
      throwsA(isA<DioException>()
          .having((error) => error.type, 'type', DioExceptionType.cancel)),
    );
    await started.future;
    final other = dio.get('/update/check');
    token.cancel('离开搜索页');
    await cancelExpectation.timeout(const Duration(seconds: 1));
    expect(requests, isEmpty);
    gate.complete(_device());
    await other;
    expect(requests.map((request) => request.path), ['/update/check']);
    expect(requests.single.queryParameters['client_device'],
        testRegisteredDeviceJson);
  });

  test('注册失败不发业务请求，后续请求可重新准备设备', () async {
    var attempts = 0;
    final requests = <RequestOptions>[];
    final dio = _client(() async {
      if (++attempts == 1) throw StateError('注册暂不可用');
      return _device();
    }, requests);
    await expectLater(dio.get('/notice'), throwsA(isA<DioException>()));
    expect(requests, isEmpty);
    await dio.get('/notice');
    expect(attempts, 2);
    expect(requests.single.queryParameters['client_device'],
        testRegisteredDeviceJson);
  });
}
