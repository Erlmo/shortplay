import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/app_update.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/app_update_service.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/app_update_dialog.dart';

const release =
    AppUpdate(version: '3.2.6', downloadUrl: 'https://example.com/update.apk');

class TvUpdates extends AppUpdateService {
  TvUpdates(ApiClient client) : super(apiClient: client);
  Completer<String>? pending;
  void Function(int, int)? progress;
  int downloads = 0;
  int installs = 0;
  bool allowed = false;
  Object? failure;
  @override
  Future<String> downloadApk(AppUpdate update,
      {required CancelToken cancelToken,
      required void Function(int, int) onProgress}) {
    downloads++;
    progress = onProgress;
    pending = Completer<String>();
    final job = pending!;
    unawaited(cancelToken.whenCancel.then((error) {
      if (!job.isCompleted) job.completeError(error);
    }));
    return job.future;
  }

  @override
  Future<String> installApk(String path) async {
    installs++;
    if (failure != null) throw failure!;
    return allowed ? 'installer_opened' : 'permission_required';
  }

  @override
  Future<bool> canInstallApks() async => allowed;
  @override
  Future<void> openUpdate(AppUpdate update) => throw StateError('TV不能打开浏览器');
}

class DownloadAdapter implements HttpClientAdapter {
  DownloadAdapter({this.slow = false});
  final bool slow;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? request,
      Future<void>? cancelFuture) async {
    requests.add(options);
    final stream = slow
        ? (() async* {
            yield Uint8List(32);
            await Future<void>.delayed(const Duration(milliseconds: 50));
            yield Uint8List(32);
          })()
        : Stream.value(Uint8List.fromList([80, 75, 3, 4]));
    return ResponseBody(stream, 200, headers: {
      Headers.contentLengthHeader: [slow ? '64' : '4']
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => DeviceProfile.isTv = true);
  tearDown(() => DeviceProfile.isTv = false);

  Future<TvUpdates> open(WidgetTester tester, {bool required = false}) async {
    final client = ApiClient();
    final service = TvUpdates(client);
    addTearDown(() {
      service.dispose();
      client.dispose();
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AppUpdateDialog(
      update: required
          ? const AppUpdate(
              version: '3.2.6',
              downloadUrl: 'https://example.com/update.apk',
              isRequired: true)
          : release,
      service: service,
    ))));
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('TV遥控器下载、进度、取消和失败重试，全程不打开浏览器', (tester) async {
    final service = await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(service.downloads, 1);
    service.progress!(524288, 1048576);
    await tester.pump();
    expect(find.text('50%  ·  0.5 / 1.0 MB'), findsOneWidget);
    expect(find.text('取消下载'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('下载已取消，可以重新下载'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(service.downloads, 2);
    service.pending!.completeError(ApiException('下载断开'));
    await tester.pumpAndSettle();
    expect(find.text('重新下载'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(service.downloads, 3);
    service.pending!.complete('/tmp/synthetic.apk');
    await tester.pumpAndSettle();
    expect(service.installs, 1);
    expect(find.text('允许安装并继续'), findsOneWidget);
    service.allowed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(service.installs, 2);
    expect(find.text('再次安装'), findsOneWidget);
  });

  testWidgets('TV强制更新下载可取消，但不提供跳过入口', (tester) async {
    await open(tester, required: true);
    expect(find.text('稍后'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('下载已取消，可以重新下载'), findsOneWidget);
    expect(find.text('稍后'), findsNothing);
  });

  testWidgets('TV按钮左右方向键切换焦点并能确认稍后', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    final later =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '稍后'));
    final focus = Focus.of(tester.element(find.text('稍后')));
    expect(focus.hasFocus, isTrue);
    expect(later.onPressed, isNotNull);
  });

  for (final cancel in [false, true]) {
    test('下载${cancel ? '取消清理半包' : '落盘且不带业务签名'}', () async {
      final directory =
          await Directory.systemTemp.createTemp('shortplay-update-');
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('shortplay/update');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel,
              (call) async =>
                  call.method == 'updateDirectory' ? directory.path : null);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final adapter = DownloadAdapter(slow: cancel);
      final client = ApiClient();
      final service = AppUpdateService(
          apiClient: client,
          downloadClientFactory: () => Dio()..httpClientAdapter = adapter);
      addTearDown(() {
        service.dispose();
        client.dispose();
      });
      final token = CancelToken();
      final request = service.downloadApk(release, cancelToken: token,
          onProgress: (received, total) {
        if (cancel && received > 0) token.cancel('取消');
      });
      if (cancel) {
        await expectLater(
            request,
            throwsA(isA<DioException>()
                .having(CancelToken.isCancel, 'cancelled', true)));
        expect(await directory.list().toList(), isEmpty);
      } else {
        final path = await request;
        expect(await File(path).readAsBytes(), [80, 75, 3, 4]);
        expect(path.endsWith('.apk'), isTrue);
        expect(adapter.requests.single.headers.containsKey('X-Dusa'), isFalse);
      }
    });
  }
}
