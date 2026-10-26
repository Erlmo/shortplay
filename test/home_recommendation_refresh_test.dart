import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/home/home_drama_card.dart';
import 'package:shortplay/pages/home/home_feed_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/app_route_observer.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/services/download_service.dart';

class _HomeApi extends ApiClient {
  _HomeApi({this.hasMore = false}) : super(baseUrl: 'https://home.test') {
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.reject(DioException(
        requestOptions: request,
        error: StateError('未预期的网络请求: ${request.path}'),
      ));
    }));
  }

  final bool hasMore;
  final homeRequests = <({int? offset, String? sessionId})>[];
  String recommendationLabel = '原推荐';

  @override
  Future<HomePageResult> fetchHomePage({int? offset, String? sessionId}) async {
    homeRequests.add((offset: offset, sessionId: sessionId));
    final start = offset == null ? 1 : 41;
    return HomePageResult(
      offset: offset ?? 0,
      sessionId: '浏览会话',
      count: 40,
      hasMore: hasMore && offset == null,
      nextOffset: 73,
      list: List.generate(
        40,
        (index) => Drama.fromJson({
          'id': start + index,
          'name': '$recommendationLabel${start + index}',
        }),
      ),
    );
  }

  @override
  Future<List<String>> fetchNotice() async => [];

  @override
  Future<NewPlayResult> fetchNewPlay(
          {int? offset, String? sessionId, String? cellGender}) async =>
      NewPlayResult(
        offset: 0,
        sessionId: '',
        count: 0,
        hasMore: false,
        nextOffset: 0,
        list: const [],
      );

  @override
  Future<RankListResult> fetchRankList({
    required String rankType,
    String type = 'all',
    String? cellGender,
    int? offset,
    String? sessionId,
  }) async =>
      RankListResult(
        offset: 0,
        sessionId: '',
        count: 0,
        hasMore: false,
        nextOffset: 0,
        list: const [],
      );
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required _HomeApi api,
  required DownloadService downloads,
  required GlobalKey<NavigatorState> navigator,
}) async {
  await tester.runAsync(downloads.ensureLoaded);
  await tester.pumpWidget(MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [appRouteObserver],
    home: Scaffold(
      body: HomeFeedPage(
        apiClient: api,
        downloadService: downloads,
        onTvTopBarFocusChanged: (_) {},
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

ScrollController _homeScroll(WidgetTester tester) => tester
    .widget<CustomScrollView>(find.byType(CustomScrollView).first)
    .controller!;

List<String> _visibleDramaNames(WidgetTester tester) => tester
    .widgetList<HomeDramaCard>(find.byType(HomeDramaCard))
    .map((card) => card.drama.name)
    .toList();

void _openPlayer(GlobalKey<NavigatorState> navigator) {
  navigator.currentState!.push(MaterialPageRoute<void>(
    builder: (_) => const Scaffold(body: Text('播放页')),
  ));
}

void main() {
  setUp(() {
    DeviceProfile.isTv = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('从播放页返回首页保留原列表和滚动位置', (tester) async {
    final api = _HomeApi();
    final downloads = DownloadService(
        apiClient: api, documentsDirectory: () async => Directory.systemTemp);
    final navigator = GlobalKey<NavigatorState>();
    try {
      await _pumpHome(tester,
          api: api, downloads: downloads, navigator: navigator);
      expect(api.homeRequests, hasLength(1));
      _homeScroll(tester).jumpTo(800);
      await tester.pumpAndSettle();
      final offset = _homeScroll(tester).offset;
      final original = _visibleDramaNames(tester);
      expect(offset, greaterThan(0));
      expect(original, isNotEmpty);

      _openPlayer(navigator);
      await tester.pumpAndSettle();
      api.recommendationLabel = '新推荐';
      expect(api.homeRequests, hasLength(1));

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(api.homeRequests, hasLength(1));
      expect(_homeScroll(tester).offset, offset);
      expect(_visibleDramaNames(tester), original);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      downloads.dispose();
      api.dispose();
    }
  });

  testWidgets('返回首页和回前台不刷新，手动刷新才更新推荐', (tester) async {
    final api = _HomeApi();
    final downloads = DownloadService(
        apiClient: api, documentsDirectory: () async => Directory.systemTemp);
    final navigator = GlobalKey<NavigatorState>();
    try {
      await _pumpHome(tester,
          api: api, downloads: downloads, navigator: navigator);
      _homeScroll(tester).jumpTo(800);
      await tester.pumpAndSettle();
      final offset = _homeScroll(tester).offset;
      final original = _visibleDramaNames(tester);
      _openPlayer(navigator);
      await tester.pumpAndSettle();

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      api.recommendationLabel = '新推荐';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(api.homeRequests, hasLength(1));
      expect(_homeScroll(tester).offset, offset);
      expect(_visibleDramaNames(tester), original);

      _homeScroll(tester).jumpTo(0);
      await tester.pumpAndSettle();
      final refresh = tester
          .state<RefreshIndicatorState>(find.byType(RefreshIndicator).first)
          .show();
      await tester.pumpAndSettle();
      await refresh;
      expect(api.homeRequests, hasLength(2));
      expect(api.homeRequests.last, (offset: null, sessionId: null));
      expect(find.text('新推荐1'), findsOneWidget);
      expect(find.text('原推荐1'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      downloads.dispose();
      api.dispose();
    }
  });

  testWidgets('退出播放页后继续翻页沿用原会话和游标', (tester) async {
    final api = _HomeApi(hasMore: true);
    final downloads = DownloadService(
        apiClient: api, documentsDirectory: () async => Directory.systemTemp);
    final navigator = GlobalKey<NavigatorState>();
    try {
      await _pumpHome(tester,
          api: api, downloads: downloads, navigator: navigator);
      expect(api.homeRequests, [(offset: null, sessionId: null)]);
      _openPlayer(navigator);
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(api.homeRequests, hasLength(1));

      final controller = _homeScroll(tester);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(api.homeRequests, hasLength(2));
      expect(api.homeRequests.last, (offset: 73, sessionId: '浏览会话'));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      downloads.dispose();
      api.dispose();
    }
  });
}
