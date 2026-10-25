import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shortplay/models/registered_device.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_registration_service.dart';
import 'package:shortplay/services/playback_report_queue.dart';

import 'support/registered_device.dart';

Map<String, dynamic> _homeResponse(RequestOptions request) => {
      'code': 0,
      'data': {
        'offset': 0,
        'session_id': 'fallback-test-session',
        'has_more': false,
        'next_offset': 0,
        'list': [],
      },
    };

class _Backend {
  _Backend(this.respond);

  final FutureOr<Map<String, dynamic>> Function(RequestOptions) respond;
  final List<RequestOptions> requests = [];

  void attach(ApiClient client) {
    client.dio.interceptors.add(InterceptorsWrapper(
      onRequest: (request, handler) async {
        requests.add(request);
        try {
          handler.resolve(Response(
            requestOptions: request,
            statusCode: 200,
            data: await respond(request),
          ));
        } catch (error) {
          handler.reject(DioException(
            requestOptions: request,
            error: error,
            type: DioExceptionType.connectionError,
          ));
        }
      },
    ));
  }
}

Map<String, dynamic> _requestDevice(RequestOptions request) =>
    jsonDecode(request.queryParameters['client_device'] as String)
        as Map<String, dynamic>;

Future<void> _drain(WidgetTester tester) async {
  // 消化 Dio 拦截器的短任务；总计 30 毫秒，远短于后台重试间隔。
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<Map<String, dynamic>> _savedQueue() async {
  final prefs = await SharedPreferences.getInstance();
  return jsonDecode(prefs.getString(PlaybackReportQueue.storageKey)!)
      as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('首次失败先显示默认数据，后台注册成功后首页请求切换并通知刷新', (tester) async {
    var attempts = 0;
    final backend = _Backend((request) {
      if (request.path == '/device/register') {
        if (++attempts == 1) throw StateError('registration unavailable');
        return {'code': 0, 'data': testRegisteredDevice};
      }
      return _homeResponse(request);
    });
    final client = ApiClient(baseUrl: 'https://fallback.test');
    backend.attach(client);
    try {
      var firstLoaded = false;
      final firstPage = client.fetchHomePage().then((_) => firstLoaded = true);
      await _drain(tester);
      expect(firstLoaded, isTrue,
          reason: 'paths: ${backend.requests.map((r) => r.path).toList()}');
      await firstPage;
      expect(_requestDevice(backend.requests.last),
          RegisteredDevice.defaultDevice.toJson());
      expect(client.deviceRevision.value, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(DeviceRegistrationService.storageKey), isFalse);

      // 默认期间连续刷新不反复打注册接口；网络重试交给后台调度。
      final secondPage = client.fetchHomePage();
      await _drain(tester);
      await secondPage;
      expect(attempts, 1);
      await tester.pump(const Duration(seconds: 5));
      await _drain(tester);
      expect(attempts, 2);
      expect(client.deviceRevision.value, 1);
      expect(jsonDecode(prefs.getString(DeviceRegistrationService.storageKey)!),
          testRegisteredDevice);

      final ownPage = client.fetchHomePage();
      await _drain(tester);
      await ownPage;
      expect(_requestDevice(backend.requests.last), testRegisteredDevice);
      await tester.pump(const Duration(minutes: 2));
      await _drain(tester);
      expect(attempts, 2);
    } finally {
      client.dispose();
    }
  });

  testWidgets('注册挂起超过三秒也先加载首页，原请求迟到成功仍能切换身份', (tester) async {
    final registration = Completer<Map<String, dynamic>>();
    var attempts = 0;
    final backend = _Backend((request) {
      if (request.path == '/device/register') {
        attempts++;
        return registration.future;
      }
      return _homeResponse(request);
    });
    final client = ApiClient(baseUrl: 'https://fallback.test');
    backend.attach(client);
    try {
      var loaded = false;
      final first = client.fetchHomePage().then((_) => loaded = true);
      await _drain(tester);
      expect(loaded, isFalse);
      await tester.pump(const Duration(seconds: 3));
      await _drain(tester);
      expect(loaded, isTrue);
      await first;
      expect(_requestDevice(backend.requests.last),
          RegisteredDevice.defaultDevice.toJson());
      expect(attempts, 1);

      // 超时只是结束首屏等待，不丢弃已在途的真实注册结果。
      registration.complete({'code': 0, 'data': testRegisteredDevice});
      await _drain(tester);
      expect(client.deviceRevision.value, 1);
      final ownPage = client.fetchHomePage();
      await _drain(tester);
      await ownPage;
      expect(_requestDevice(backend.requests.last), testRegisteredDevice);
      expect(attempts, 1);
    } finally {
      if (!registration.isCompleted) {
        registration.complete({'code': 0, 'data': testRegisteredDevice});
        await _drain(tester);
      }
      client.dispose();
    }
  });

  test('默认期间观看只在本地排队，注册恢复后以自己的设备补发且时长不丢失', () async {
    var available = false;
    var registrations = 0;
    final service = DeviceRegistrationService(registerDevice: () async {
      registrations++;
      if (!available) throw StateError('registration unavailable');
      return testRegisteredDevice;
    });
    final backend =
        _Backend((request) => request.path == '/nove/playback/report'
            ? {
                'code': 0,
                'data': {
                  'accepted': true,
                  'count': ((request.data as Map)['books'] as List).length,
                },
              }
            : _homeResponse(request));
    final client = ApiClient(
      baseUrl: 'https://fallback.test',
      deviceRegistrationService: service,
    );
    backend.attach(client);
    try {
      await client.initializeDevice();
      await client.fetchHomePage();
      expect(service.isUsingDefaultDevice, isTrue);
      expect(_requestDevice(backend.requests.last),
          RegisteredDevice.defaultDevice.toJson());
      expect(await service.readCachedDevice(), isNull);

      await client.playbackReports.checkpoint(
        bookId: '123',
        itemId: '456',
        positionMs: 15000,
        playedDeltaMs: 5000,
        vidIndex: 1,
        timestampMs: 10000,
      );
      await client.playbackReports.flush(force: true);
      expect(backend.requests.where((r) => r.path == '/nove/playback/report'),
          isEmpty);
      expect(registrations, 1);
      var saved = await _savedQueue();
      expect(saved['owner'], isNull);
      expect((saved['pending'] as List).single,
          containsPair('player_cumulative_total_duration', 5000));

      available = true;
      await service.retryRegistration();
      await client.playbackReports.flush(force: true);
      expect(service.isUsingDefaultDevice, isFalse);
      final reports = backend.requests
          .where((r) => r.path == '/nove/playback/report')
          .toList();
      expect(reports, hasLength(1));
      expect(_requestDevice(reports.single), testRegisteredDevice);
      final books = (reports.single.data as Map)['books'] as List;
      expect(books.single, containsPair('current_play_time', 15000));
      expect(
          books.single, containsPair('player_cumulative_total_duration', 5000));
      saved = await _savedQueue();
      expect(saved['owner'],
          '${testRegisteredDevice['device_id']}:${testRegisteredDevice['install_id']}');
      expect(saved['pending'], isEmpty);

      await client.playbackReports.checkpoint(
        bookId: '123',
        itemId: '456',
        positionMs: 16000,
        playedDeltaMs: 1000,
        vidIndex: 1,
        timestampMs: 11000,
      );
      await client.playbackReports.flush(force: true);
      final latest = backend.requests.last;
      expect(_requestDevice(latest), testRegisteredDevice);
      expect(((latest.data as Map)['books'] as List).single,
          containsPair('player_cumulative_total_duration', 6000));
    } finally {
      client.dispose();
      service.dispose();
    }
  });
}
