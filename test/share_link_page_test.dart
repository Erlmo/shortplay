import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/drama_detail_page.dart';
import 'package:shortplay/pages/share_link_page.dart';
import 'package:shortplay/services/api_client.dart';

typedef _ShareInfo = ({String videoId, String? title});

class _ShareRequest {
  _ShareRequest(this.text);

  final String text;
  final result = Completer<_ShareInfo>();
}

Drama _completeDrama(String id, String title) => Drama(
      id: int.parse(id),
      name: title,
      actors: '演员甲、演员乙',
      cover: 'https://example.com/drama-cover.jpg',
      intro: '完整的短剧简介',
      tags: ['重生', '都市'],
      status: '已完结',
      updateTime: '全80集',
      score: '9.1',
      recText: '100万热度',
      isTheaterResource: true,
    );

class _DetailRequest {
  _DetailRequest(this.dramaId, this.title);

  final String dramaId;
  final String title;
  final result = Completer<Drama>();
}

class _ShareApiClient extends ApiClient {
  final requests = <_ShareRequest>[];
  final detailRequests = <_DetailRequest>[];
  bool holdDetailRequests = false;

  @override
  Future<_ShareInfo> fetchShareInfo(String text) {
    final request = _ShareRequest(text);
    requests.add(request);
    return request.result.future;
  }

  @override
  Future<Drama> fetchSharedDramaDetail(String dramaId,
      {required String title}) {
    final request = _DetailRequest(dramaId, title);
    detailRequests.add(request);
    if (title.trim().isEmpty) {
      request.result.completeError(ApiException('未获得剧名，请复制完整分享口令后重试'));
    } else if (!holdDetailRequests) {
      request.result.complete(_completeDrama(dramaId, title));
    }
    return request.result.future;
  }

  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String dramaId) async =>
      TheaterEpisodesResult(allItemIds: [], chapters: []);
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
  });

  tearDown(() {
    apiClient.dio.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> openPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: ShareLinkPage(
        apiClient: apiClient,
      ),
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
    expect(find.byType(DramaDetailPage), findsNothing);
  });

  testWidgets('提交完整分享口令，服务端剧名优先并打开对应短剧', (tester) async {
    const shareText = '《口令里的剧名》免费看全集\nhttps://novelquickapp.com/s/example';
    apiClient.holdDetailRequests = true;
    await openPage(tester);
    await submit(tester, shareText);

    expect(apiClient.requests.single.text, shareText);
    apiClient.requests.single.result.complete((
      videoId: '7600753386882878489',
      title: '服务端返回的剧名',
    ));
    await tester.pump();

    expect(find.byType(DramaDetailPage), findsNothing);
    final detailRequest = apiClient.detailRequests.single;
    expect(detailRequest.dramaId, '7600753386882878489');
    expect(detailRequest.title, '服务端返回的剧名');
    final fullDrama =
        _completeDrama(detailRequest.dramaId, detailRequest.title);
    detailRequest.result.complete(fullDrama);
    await tester.pumpAndSettle();

    final detail = tester.widget<DramaDetailPage>(find.byType(DramaDetailPage));
    expect(detail.drama, same(fullDrama));
    expect(detail.drama.id, 7600753386882878489);
    expect(detail.drama.name, '服务端返回的剧名');
    expect(detail.drama.cover, 'https://example.com/drama-cover.jpg');
    expect(detail.drama.intro, '完整的短剧简介');
    expect(detail.drama.actors, '演员甲、演员乙');
    expect(detail.drama.tags, ['重生', '都市']);
    expect(detail.drama.score, '9.1');
    expect(detail.drama.updateTime, '全80集');
    expect(detail.drama.status, '已完结');
    expect(detail.drama.recText, '100万热度');
    expect(detail.drama.isTheaterResource, isTrue);
    expect(detail.apiClient, same(apiClient));
  });

  testWidgets('服务端没有剧名时使用分享口令中的剧名', (tester) async {
    await openPage(tester);
    await submit(tester, '《口令剧名》https://novelquickapp.com/s/example');
    apiClient.requests.single.result.complete((videoId: '123', title: null));
    await tester.pumpAndSettle();

    final detail = tester.widget<DramaDetailPage>(find.byType(DramaDetailPage));
    expect(detail.drama.id, 123);
    expect(detail.drama.name, '口令剧名');
    expect(apiClient.detailRequests.single.dramaId, '123');
    expect(apiClient.detailRequests.single.title, '口令剧名');
  });

  testWidgets('纯分享链接没有剧名时明确提示而不进入空详情', (tester) async {
    await openPage(tester);
    await submit(tester, 'https://novelquickapp.com/s/example');
    apiClient.requests.single.result.complete((videoId: '123', title: null));
    await tester.pumpAndSettle();

    expect(find.byType(DramaDetailPage), findsNothing);
    expect(find.textContaining('剧名'), findsOneWidget);
    expect(find.text('开始识别'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://novelquickapp.com/s/example');
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
    expect(find.byType(DramaDetailPage), findsNothing);

    await tester.tap(find.text('开始识别'));
    await tester.pump();
    expect(apiClient.requests, hasLength(2));
    expect(apiClient.requests.last.text, shareText);
    apiClient.requests.last.result.complete((videoId: '456', title: '重试成功'));
    await tester.pumpAndSettle();
    expect(find.byType(DramaDetailPage), findsOneWidget);
  });

  testWidgets('完整详情查询失败保留分享内容并可重新识别', (tester) async {
    const shareText = '《保留完整口令》https://novelquickapp.com/s/example';
    apiClient.holdDetailRequests = true;
    await openPage(tester);
    await submit(tester, shareText);
    apiClient.requests.single.result.complete((videoId: '123', title: '短剧名'));
    await tester.pump();
    apiClient.detailRequests.single.result
        .completeError(ApiException('详情查询失败，请重试'));
    await tester.pumpAndSettle();

    expect(find.textContaining('详情查询失败'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        shareText);
    expect(find.byType(DramaDetailPage), findsNothing);

    await tester.tap(find.text('开始识别'));
    await tester.pump();
    expect(apiClient.requests, hasLength(2));
    apiClient.requests.last.result.complete((videoId: '123', title: '短剧名'));
    await tester.pump();
    expect(apiClient.detailRequests, hasLength(2));
    apiClient.detailRequests.last.result.complete(_completeDrama('123', '短剧名'));
    await tester.pumpAndSettle();

    expect(find.byType(DramaDetailPage), findsOneWidget);
  });

  for (final invalidId in ['not-an-id', '0', '-1']) {
    testWidgets('无效作品 ID $invalidId 不跳转且允许重试', (tester) async {
      await openPage(tester);
      await submit(tester, 'https://novelquickapp.com/s/example');
      apiClient.requests.single.result
          .complete((videoId: invalidId, title: '无效结果'));
      await tester.pumpAndSettle();

      expect(find.byType(DramaDetailPage), findsNothing);
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

  testWidgets('退出识别页面后迟到的响应不会打开短剧', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Text('原页面')),
    ));
    unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => ShareLinkPage(
        apiClient: apiClient,
      ),
    )));
    await tester.pumpAndSettle();
    await submit(tester, 'https://novelquickapp.com/s/example');
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    apiClient.requests.single.result.complete((videoId: '123', title: '迟到结果'));
    await tester.pumpAndSettle();
    expect(find.text('原页面'), findsOneWidget);
    expect(find.byType(DramaDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回动画尚未结束时收到识别响应也不会打开短剧', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Text('原页面')),
    ));
    unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => ShareLinkPage(
        apiClient: apiClient,
      ),
    )));
    await tester.pumpAndSettle();
    await submit(tester, 'https://novelquickapp.com/s/example');
    final sharePageState = tester.state(find.byType(ShareLinkPage));
    navigatorKey.currentState!.pop();
    // pop 已撤销路由，但退出动画期间 State 尚未被 dispose。
    expect(sharePageState.mounted, isTrue);
    apiClient.requests.single.result.complete((videoId: '123', title: '迟到结果'));
    await tester.pumpAndSettle();

    expect(find.text('原页面'), findsOneWidget);
    expect(find.byType(DramaDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final waitForExit in [true, false]) {
    testWidgets('完整详情请求中退出${waitForExit ? '页面' : '动画期间'}收到响应不跳转',
        (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      apiClient.holdDetailRequests = true;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('原页面')),
      ));
      unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => ShareLinkPage(
          apiClient: apiClient,
        ),
      )));
      await tester.pumpAndSettle();
      await submit(tester, 'https://novelquickapp.com/s/example');
      apiClient.requests.single.result.complete((videoId: '123', title: '短剧名'));
      await tester.pump();
      expect(apiClient.detailRequests, hasLength(1));
      final pageState = tester.state(find.byType(ShareLinkPage));
      navigatorKey.currentState!.pop();
      if (waitForExit) {
        await tester.pumpAndSettle();
        expect(pageState.mounted, isFalse);
      } else {
        expect(pageState.mounted, isTrue);
      }
      apiClient.detailRequests.single.result
          .complete(_completeDrama('123', '短剧名'));
      await tester.pumpAndSettle();

      expect(find.text('原页面'), findsOneWidget);
      expect(find.byType(DramaDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

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
