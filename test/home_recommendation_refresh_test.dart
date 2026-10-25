import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/pages/home/drama_list_tab.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/app_route_observer.dart';

void main() {
  testWidgets('观看上报成功后播放期间不刷新，返回首页只刷新一次', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final signal = ValueNotifier<int>(0);
    final api = ApiClient();
    addTearDown(signal.dispose);
    addTearDown(() => api.dio.close(force: true));
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [appRouteObserver],
      home: Scaffold(
          body: DramaListTab(
        apiClient: api,
        refreshSignal: signal,
        fetchFunction: (_, __, ___, ____) async {
          requests++;
          return HomePageResult(
              offset: 0,
              sessionId: 'home',
              count: 0,
              hasMore: false,
              nextOffset: 0,
              list: const []);
        },
      )),
    ));
    await tester.pumpAndSettle();
    expect(requests, 1);
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('播放页'))));
    await tester.pumpAndSettle();
    signal.value++;
    signal.value++;
    await tester.pumpAndSettle();
    expect(requests, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
