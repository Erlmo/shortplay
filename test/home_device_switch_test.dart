import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/home/drama_list_tab.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/app_route_observer.dart';
import 'package:shortplay/services/device_profile.dart';

HomePageResult _page(String title) => HomePageResult(
      offset: 0,
      sessionId: title,
      count: 1,
      hasMore: false,
      nextOffset: 0,
      list: [
        Drama.fromJson({'id': title == '默认内容' ? 1 : 2, 'name': title})
      ],
    );

Widget _home(
        ApiClient api, Future<HomePageResult> Function(int?, String?) fetch) =>
    MaterialApp(
      navigatorObservers: [appRouteObserver],
      home: Scaffold(
        body: DramaListTab(
          apiClient: api,
          fetchFunction: (_, offset, session, __) => fetch(offset, session),
        ),
      ),
    );

void main() {
  setUp(() => DeviceProfile.isTv = true);
  tearDown(() => DeviceProfile.isTv = false);

  testWidgets('独立身份切换会刷新TV列表并忽略迟到的默认设备响应', (tester) async {
    final api = ApiClient();
    final oldPage = Completer<HomePageResult>();
    var requests = 0;
    await tester.pumpWidget(_home(api, (offset, session) {
      requests++;
      expect(offset, isNull);
      expect(session, isNull);
      return requests == 1 ? oldPage.future : Future.value(_page('独立内容'));
    }));
    api.deviceRevision.value++;
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('独立内容'), findsOneWidget);
    oldPage.complete(_page('默认内容'));
    await tester.pumpAndSettle();
    expect(find.text('默认内容'), findsNothing);
    expect(find.text('独立内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dispose();
  });

  testWidgets('身份切换刷新失败时仍保留已显示的默认内容，成功后才替换', (tester) async {
    final api = ApiClient();
    final newPage = Completer<HomePageResult>();
    var requests = 0;
    await tester.pumpWidget(_home(api, (offset, session) {
      requests++;
      return requests == 1 ? Future.value(_page('默认内容')) : newPage.future;
    }));
    await tester.pumpAndSettle();
    expect(find.text('默认内容'), findsOneWidget);
    api.deviceRevision.value++;
    await tester.pump();
    expect(find.text('默认内容'), findsOneWidget);
    newPage.completeError(ApiException('首页暂不可用'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('默认内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dispose();
  });
}
