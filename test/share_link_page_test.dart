import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/pages/share_link_page.dart';
import 'package:shortplay/services/api_client.dart';

typedef _ShareInfo = ({String videoId, String? title});

class _ShareRequest {
  _ShareRequest(this.text);

  final String text;
  final result = Completer<_ShareInfo>();
}

class _ShareApiClient extends ApiClient {
  final requests = <_ShareRequest>[];
  final directoryIds = <String>[];
  final videoIds = <String>[];
  List<TheaterChapter> chapters = [];
  int searchRequests = 0;

  @override
  Future<_ShareInfo> fetchShareInfo(String text) {
    final request = _ShareRequest(text);
    requests.add(request);
    return request.result.future;
  }

  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String dramaId) async {
    directoryIds.add(dramaId);
    return TheaterEpisodesResult(
      allItemIds: chapters.map((chapter) => chapter.itemId).toList(),
      chapters: chapters,
    );
  }

  @override
  Future<List<FqVideoItem>> fetchFqVideoModel(String videoId) async {
    videoIds.add(videoId);
    return [];
  }

  @override
  Future<({List<Drama> dramas, bool hasMore})> search(String keyword,
      {int offset = 0}) async {
    searchRequests++;
    return (dramas: <Drama>[], hasMore: false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ShareApiClient apiClient;
  String? clipboardText;

  setUp(() {
    apiClient = _ShareApiClient();
    clipboardText = null;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return clipboardText == null ? null : {'text': clipboardText};
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/native_player'),
            (call) async => null);
  });

  tearDown(() {
    apiClient.dio.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/native_player'), null);
  });

  Future<void> openPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: ShareLinkPage(apiClient: apiClient),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('开始识别'));
    await tester.pump();
  }

  testWidgets('空白输入不发起识别请求', (tester) async {
    await openPage(tester);
    await submit(tester, '  \n  ');
    await tester.pumpAndSettle();

    expect(apiClient.requests, isEmpty);
    expect(find.byType(ShareLinkPage), findsOneWidget);
    expect(find.byType(PlayerPage), findsNothing);
  });

  testWidgets('识别成功直接打开第一集播放页，不请求搜索详情', (tester) async {
    const shareText =
        '打开红果漫剧免费看《三天后穿越古代，我贷款搬空商城！》https://kylin.hainanyuyue.com/s/KvIwxDVCTxg/';
    apiClient.chapters = [
      TheaterChapter(
        itemId: '7679385177390337048',
        title: '第1集',
        realChapterOrder: '1',
      ),
      TheaterChapter(
        itemId: '7679385177390337049',
        title: '第2集',
        realChapterOrder: '2',
      ),
    ];
    await openPage(tester);
    await submit(tester, shareText);

    expect(apiClient.requests.single.text, shareText);
    apiClient.requests.single.result.complete((
      videoId: '7679367796244892696',
      title: '服务端返回的剧名',
    ));
    await tester.pumpAndSettle();

    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.drama.id, 7679367796244892696);
    expect(player.drama.name, '服务端返回的剧名');
    expect(player.drama.isTheaterResource, isTrue);
    expect(player.apiClient, same(apiClient));
    expect(player.initialEpisodeIndex, 0);
    expect(apiClient.directoryIds, ['7679367796244892696']);
    expect(apiClient.videoIds, isNotEmpty);
    expect(apiClient.videoIds, everyElement('7679385177390337048'));
    expect(apiClient.searchRequests, 0);
  });

  testWidgets('服务端没有剧名时使用分享口令中的剧名', (tester) async {
    await openPage(tester);
    await submit(tester, '《口令剧名》https://novelquickapp.com/s/example');
    apiClient.requests.single.result.complete((videoId: '123', title: null));
    await tester.pumpAndSettle();

    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.drama.id, 123);
    expect(player.drama.name, '口令剧名');
    expect(apiClient.directoryIds, ['123']);
  });

  testWidgets('纯分享链接没有剧名也能进入播放页', (tester) async {
    await openPage(tester);
    await submit(tester, 'https://novelquickapp.com/s/example');
    apiClient.requests.single.result.complete((videoId: '123', title: null));
    await tester.pumpAndSettle();

    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.drama.name, '分享短剧');
    expect(apiClient.directoryIds, ['123']);
  });

  testWidgets('识别失败显示错误并保留输入，随后可以重试', (tester) async {
    const shareText = '《保留口令》https://novelquickapp.com/s/example';
    await openPage(tester);
    await submit(tester, shareText);
    apiClient.requests.single.result.completeError(ApiException('测试失败信息'));
    await tester.pumpAndSettle();

    expect(find.textContaining('测试失败信息'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        shareText);
    expect(find.byType(PlayerPage), findsNothing);

    await tester.tap(find.text('开始识别'));
    await tester.pump();
    expect(apiClient.requests, hasLength(2));
    apiClient.requests.last.result.complete((videoId: '456', title: '重试成功'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(apiClient.directoryIds, ['456']);
  });

  for (final invalidId in ['not-an-id', '0', '-1']) {
    testWidgets('无效作品 ID $invalidId 不跳转且允许重试', (tester) async {
      await openPage(tester);
      await submit(tester, 'https://novelquickapp.com/s/example');
      apiClient.requests.single.result
          .complete((videoId: invalidId, title: '无效结果'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerPage), findsNothing);
      expect(apiClient.directoryIds, isEmpty);
      expect(find.text('开始识别'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('请求未完成时连续点击只发起一次请求', (tester) async {
    await openPage(tester);
    await tester.enterText(
        find.byType(TextField), 'https://novelquickapp.com/s/example');
    final button = find.text('开始识别');
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();

    expect(apiClient.requests, hasLength(1));
    expect(find.text('识别中…'), findsOneWidget);
    apiClient.requests.single.result.completeError(ApiException('请求结束'));
    await tester.pumpAndSettle();
    expect(find.text('开始识别'), findsOneWidget);
  });

  testWidgets('退出识别页面后迟到的响应不会打开播放页', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Text('原页面')),
    ));
    unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => ShareLinkPage(apiClient: apiClient),
    )));
    await tester.pumpAndSettle();
    await submit(tester, 'https://novelquickapp.com/s/example');
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    apiClient.requests.single.result.complete((videoId: '123', title: '迟到结果'));
    await tester.pumpAndSettle();
    expect(find.text('原页面'), findsOneWidget);
    expect(find.byType(PlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回动画尚未结束时收到响应不会打开播放页', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Text('原页面')),
    ));
    unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => ShareLinkPage(apiClient: apiClient),
    )));
    await tester.pumpAndSettle();
    await submit(tester, 'https://novelquickapp.com/s/example');
    final pageState = tester.state(find.byType(ShareLinkPage));
    navigatorKey.currentState!.pop();
    expect(pageState.mounted, isTrue);
    apiClient.requests.single.result.complete((videoId: '123', title: '迟到结果'));
    await tester.pumpAndSettle();

    expect(find.text('原页面'), findsOneWidget);
    expect(find.byType(PlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('粘贴只填入完整口令，清空后不请求识别', (tester) async {
    clipboardText = '《剪贴板剧名》分享口令\nhttps://novelquickapp.com/s/example';
    await openPage(tester);
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        clipboardText);
    expect(apiClient.requests, isEmpty);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    expect(apiClient.requests, isEmpty);
  });
}
