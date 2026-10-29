import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/pages/home/continue_watching_bar.dart';
import 'package:shortplay/pages/home/home_feed_page.dart';
import 'package:shortplay/pages/home_page.dart';
import 'package:shortplay/pages/twixive/twixive_home_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/download_service.dart';
import 'package:shortplay/services/hidden_feed_access.dart';

import 'support/no_app_updates.dart';

class _HomeAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    Object data = {'list': [], 'has_more': false};
    const user = {
      'id': '1',
      'username': 'example',
      'name': '示例作者',
      'avatar': ''
    };
    const video = {
      'id': '123',
      'url': 'https://video.example/123.mp4',
      'thumbnail': '',
      'author': user
    };
    if (options.path == '/notice') data = <String>[];
    if (options.path.startsWith('/twixive')) {
      data = options.path == '/twixive/access'
          ? {
              'valid':
                  options.data is Map && options.data['phrase'] == 'test-pass'
            }
          : options.path == '/twixive/trendusers'
              ? {
                  'items': [
                    {'user': user}
                  ]
                }
              : options.path == '/twixive/uservideos'
                  ? {
                      'user': user,
                      'videos': [video],
                      'pageInfo': {'nextCursor': null, 'hasNextPage': false}
                    }
                  : {
                      'items': [
                        {'video': video}
                      ]
                    };
    }
    return ResponseBody.fromString(jsonEncode({'code': 0, 'data': data}), 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('点击版本不再解锁，识别页仅在服务端验证成功后切换首页', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final adapter = _HomeAdapter();
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    final downloads = DownloadService(
        apiClient: api, documentsDirectory: () async => Directory.systemTemp);
    await tester.runAsync(downloads.ensureLoaded);
    addTearDown(downloads.dispose);
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(
        home: HomePage(
            apiClient: api,
            downloadService: downloads,
            appUpdateService: NoAppUpdates(api))));
    await tester.pumpAndSettle();
    expect(find.byType(HomeFeedPage), findsOneWidget);
    expect(
        adapter.requests.where((r) => r.path.startsWith('/twixive')), isEmpty);

    // 旧点击入口已删除：重复设置、版本都不触发验证或解锁。
    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.tap(find.text('设置'));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('软件版本'));
      await tester.pump();
    }
    expect(find.byType(TwixiveHomePage), findsNothing);
    expect(
        (await SharedPreferences.getInstance())
            .getBool(HiddenFeedAccess.preferenceKey),
        isNot(true));
    await tester.tap(find.text('首页'));
    await tester.pump();

    var checkedInvalidPhrase = false;
    Future<void> switchMode() async {
      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.tap(find.text('分享链接识别'));
      await tester.pumpAndSettle();
      if (!checkedInvalidPhrase) {
        await tester.enterText(find.byType(TextField), 'wrong-pass');
        await tester.tap(find.text('开始识别'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        expect(find.byType(TwixiveHomePage), findsNothing);
        expect(
            (await SharedPreferences.getInstance())
                .getBool(HiddenFeedAccess.preferenceKey),
            isNot(true));
        checkedInvalidPhrase = true;
      }
      await tester.enterText(find.byType(TextField), 'test-pass');
      await tester.tap(find.text('开始识别'));
      await tester.pumpAndSettle();
    }

    await switchMode();
    expect(find.byType(TwixiveHomePage), findsOneWidget);
    expect(find.widgetWithText(Tab, '喜欢'), findsOneWidget);
    expect(find.byType(HomeFeedPage), findsNothing);
    expect(find.byType(ContinueWatchingBar), findsNothing);
    expect(
        (await SharedPreferences.getInstance())
            .getBool(HiddenFeedAccess.preferenceKey),
        isTrue);

    await tester.tap(find.widgetWithText(Tab, '排行榜'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '3 日'));
    await tester.pumpAndSettle();
    expect(
        adapter.requests.any((r) =>
            r.path == '/twixive/ranking' && r.queryParameters['days'] == 3),
        isTrue);
    expect(find.widgetWithText(Tab, '热播'), findsNothing);
    expect(find.widgetWithText(Tab, '推荐'), findsNothing);

    await tester.tap(find.widgetWithText(Tab, '用户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('示例作者').hitTestable().last);
    await tester.pumpAndSettle();
    expect(find.byType(TwixiveUserPage), findsOneWidget);
    expect(
        adapter.requests.any((r) =>
            r.path == '/twixive/uservideos' &&
            r.queryParameters['user'] == 'example'),
        isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await switchMode();
    expect(find.byType(HomeFeedPage), findsOneWidget);
    expect(find.byType(TwixiveHomePage), findsNothing);
    expect(
        (await SharedPreferences.getInstance())
            .getBool(HiddenFeedAccess.preferenceKey),
        isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('记住隐藏模式，重启后直接加载新首页，不请求普通首页', (tester) async {
    SharedPreferences.setMockInitialValues(
        {HiddenFeedAccess.preferenceKey: true});
    final adapter = _HomeAdapter();
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    final downloads = DownloadService(
        apiClient: api, documentsDirectory: () async => Directory.systemTemp);
    await tester.runAsync(downloads.ensureLoaded);
    addTearDown(downloads.dispose);
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(
        home: HomePage(
            apiClient: api,
            downloadService: downloads,
            appUpdateService: NoAppUpdates(api))));
    await tester.pumpAndSettle();
    expect(find.byType(TwixiveHomePage), findsOneWidget);
    expect(find.byType(HomeFeedPage), findsNothing);
    expect(adapter.requests.any((r) => r.path == '/nove/home'), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
