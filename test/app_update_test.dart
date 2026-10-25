import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shortplay/models/app_update.dart';
import 'package:shortplay/pages/settings_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/app_update_service.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/app_update_gate.dart';

import 'support/registered_device.dart';

const _release = AppUpdate(
  version: '3.2.1',
  releaseNotes: '改善使用体验',
  downloadUrl: 'https://downloads.example/android64.apk',
);
const _requiredRelease = AppUpdate(
  version: '3.2.1',
  downloadUrl: 'https://downloads.example/android64.apk',
  isRequired: true,
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.response);
  final ResponseBody Function(RequestOptions) response;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      response(options);

  @override
  void close({bool force = false}) {}
}

class _Updates extends AppUpdateService {
  _Updates(ApiClient client) : super(apiClient: client);

  AppUpdate? available = _release;
  AppUpdate? policy;
  Object? checkError;
  Object? openError;
  int opens = 0;
  int checks = 0;
  String? openedUrl;

  @override
  AppUpdate? get requiredUpdate => policy;

  @override
  Future<AppUpdate?> check({CancelToken? cancelToken}) async {
    checks++;
    if (checkError != null) throw checkError!;
    policy = available?.isRequired == true ? available : null;
    notifyListeners();
    return available;
  }

  @override
  Future<void> openUpdate(AppUpdate update) async {
    opens++;
    if (openError != null) throw openError!;
    openedUrl = update.downloadUrl;
  }
}

Future<_Updates> _openSettings(WidgetTester tester) async {
  final client = ApiClient();
  addTearDown(() => client.dio.close(force: true));
  final service = _Updates(client);
  addTearDown(service.dispose);
  await tester.pumpWidget(MaterialApp(
      home: SettingsPage(apiClient: client, appUpdateService: service)));
  await tester.pumpAndSettle();
  return service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String detectedDevice = 'android64';
  final openedUrls = <String>[];

  setUp(() {
    PackageInfo.setMockInitialValues(
        appName: '龙龙短剧',
        packageName: 'com.example.shortplay',
        version: '3.2.0',
        buildNumber: '12',
        buildSignature: '');
    detectedDevice = 'android64';
    openedUrls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('shortplay/update'),
            (call) async {
      if (call.method == 'device') return detectedDevice;
      if (call.method == 'openUrl') {
        openedUrls.add((call.arguments as Map)['url'] as String);
        return true;
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/update'), null);
  });

  for (final device in ['ios', 'android32', 'android64']) {
    test('$device 使用设备与版本查询，并打开对应下载链接', () async {
      debugDefaultTargetPlatformOverride =
          device == 'ios' ? TargetPlatform.iOS : TargetPlatform.android;
      detectedDevice = device;
      final url = 'https://downloads.example/$device';
      final dio = Dio(BaseOptions(baseUrl: 'https://updates.example'));
      final client = ApiClient(dio: dio);
      final service = AppUpdateService(apiClient: client);
      addTearDown(service.dispose);
      addTearDown(() => dio.close(force: true));
      dio.httpClientAdapter = _Adapter((options) {
        expect(options.path, '/update/check');
        expect(options.queryParameters, {
          'device': device,
          'version': '3.2.0',
          'client_device': testRegisteredDeviceJson,
        });
        return ResponseBody.fromString(
            jsonEncode({
              'code': 0,
              'data': {
                'update_available': true,
                'version': '3.2.1',
                'download_url': url,
                'force_update': device == 'ios',
              }
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType]
            });
      });
      final update = await service.check();
      expect(update!.downloadUrl, url);
      expect(update.isRequired, device == 'ios');
      await service.openUpdate(update);
      expect(openedUrls, [url]);
    });
  }

  test('不可信下载协议和非布尔强制标记被拒绝，兼容 iOS 安装链接', () {
    Map<String, Object> data(String url, Object force) => {
          'update_available': true,
          'version': '3.2.1',
          'download_url': url,
          'force_update': force,
        };
    for (final invalid in [
      data('file:///tmp/update.apk', false),
      data('javascript:alert(1)', false),
      data('https://downloads.example/app.apk', 'false'),
      data('', false),
    ]) {
      expect(() => AppUpdate.fromResponse(invalid),
          throwsA(isA<FormatException>()));
    }
    final manifest =
        'itms-services://?action=download-manifest&url=https%3A%2F%2Fdownloads.example%2Fapp.plist';
    expect(AppUpdate.fromResponse(data(manifest, true))!.downloadUrl, manifest);
    expect(AppUpdate.fromResponse({'update_available': false}), isNull);
  });

  testWidgets('设置入口展示最新版和检查失败提示', (tester) async {
    final service = await _openSettings(tester);
    service.available = null;
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('当前已是最新版本'), findsOneWidget);
    service.checkError = ApiException('网络不可用');
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('检查更新失败'), findsOneWidget);
    expect(find.text('网络不可用'), findsOneWidget);
  });

  testWidgets('普通更新可稍后，遥控器确认打开链接且打开失败可重试', (tester) async {
    DeviceProfile.isTv = true;
    addTearDown(() => DeviceProfile.isTv = false);
    final service = await _openSettings(tester);
    service.openError = ApiException('没有浏览器');
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('稍后'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('没有浏览器'), findsOneWidget);
    service.openError = null;
    await tester.tap(find.text('立即更新'));
    await tester.pumpAndSettle();
    expect(service.openedUrl, _release.downloadUrl);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 3.2.1'), findsNothing);
  });

  testWidgets('启动强制更新无法返回跳过，打开链接返回后仍需更新，策略取消后恢复', (tester) async {
    final client = ApiClient();
    final service = _Updates(client)..available = _requiredRelease;
    addTearDown(service.dispose);
    addTearDown(() => client.dio.close(force: true));
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => AppUpdateGate(service: service, child: child!),
      home: const Scaffold(body: Text('应用页面')),
    ));
    await tester.pumpAndSettle();
    expect(service.checks, 1);
    expect(find.text('需要更新至 3.2.1'), findsOneWidget);
    expect(find.text('稍后'), findsNothing);
    expect(find.text('应用页面'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('需要更新至 3.2.1'), findsOneWidget);
    await tester.tap(find.text('立即更新'));
    await tester.pumpAndSettle();
    expect(service.openedUrl, _requiredRelease.downloadUrl);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('需要更新至 3.2.1'), findsOneWidget);
    service.available = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('应用页面'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
