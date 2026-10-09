import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/main.dart';
import 'package:shortplay/pages/global_search_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/download_service.dart';

class _ClipboardApiClient extends ApiClient {
  int requests = 0;

  @override
  Future<({String videoId, String? title})> fetchShareInfo(String text) {
    requests++;
    return Future.value((videoId: '123', title: '分享短剧'));
  }
}

void main() {
  testWidgets('启动和回前台不读取剪贴板，分享内容仅由用户主动粘贴', (tester) async {
    final apiClient = _ClipboardApiClient();
    final downloads = DownloadService(apiClient: apiClient);
    addTearDown(downloads.dispose);
    addTearDown(() => apiClient.dio.close(force: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var clipboardReads = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        clipboardReads++;
        return {'text': '《分享短剧》https://novelquickapp.com/s/example'};
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ShortPlayApp(
      apiClient: apiClient,
      downloadService: downloads,
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(clipboardReads, 0);
    expect(apiClient.requests, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(clipboardReads, 0);
    expect(apiClient.requests, 0);
    expect(find.text('发现短剧口令'), findsNothing);

    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.tap(find.text('分享链接识别'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(clipboardReads, 0);
    expect(apiClient.requests, 0);
    expect(find.text('发现短剧口令'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('粘贴'));
    await tester.pump();
    expect(clipboardReads, 1);
    expect(apiClient.requests, 0);
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '《分享短剧》https://novelquickapp.com/s/example');
  });

  testWidgets('底部设置入口可以打开分享链接识别页面', (tester) async {
    final apiClient = ApiClient();
    final downloads = DownloadService(apiClient: apiClient);
    addTearDown(downloads.dispose);
    addTearDown(() => apiClient.dio.close(force: true));
    await tester.pumpWidget(ShortPlayApp(
      apiClient: apiClient,
      downloadService: downloads,
    ));
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.tap(find.text('分享链接识别'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('开始识别'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('分享链接识别'), findsOneWidget);
  });

  testWidgets('首页搜索入口打开搜索页面', (tester) async {
    final apiClient = ApiClient();
    await tester.pumpWidget(ShortPlayApp(
      apiClient: apiClient,
      downloadService: DownloadService(apiClient: apiClient),
    ));
    expect(find.byIcon(Icons.search), findsOneWidget);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(GlobalSearchPage), findsOneWidget);
  });
}
