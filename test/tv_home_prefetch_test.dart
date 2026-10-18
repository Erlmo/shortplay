import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/home_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/services/download_service.dart';

typedef _Request = ({int? offset, String? sessionId, String type});

class _FeedApi extends ApiClient {
  final homeRequests = <_Request>[];
  final rankRequests = <_Request>[];
  Future<HomePageResult> Function(_Request)? homeReply;
  Future<HomePageResult> Function(_Request)? rankReply;

  @override
  Future<List<String>> fetchNotice() async => [];

  @override
  Future<HomePageResult> fetchHomePage({int? offset, String? sessionId}) {
    final request = (offset: offset, sessionId: sessionId, type: 'all');
    homeRequests.add(request);
    return homeReply?.call(request) ?? Future.value(_page(hasMore: false));
  }

  @override
  Future<NewPlayResult> fetchNewPlay(
          {int? offset, String? sessionId, String? cellGender}) async =>
      NewPlayResult(
          offset: 0,
          sessionId: '',
          count: 0,
          hasMore: false,
          nextOffset: 0,
          list: []);

  @override
  Future<RankListResult> fetchRankList({
    required String rankType,
    String type = 'all',
    String? cellGender,
    int? offset,
    String? sessionId,
  }) async {
    if (rankType != 'recommend') {
      return RankListResult(
          offset: 0,
          sessionId: '',
          count: 0,
          hasMore: false,
          nextOffset: 0,
          list: []);
    }
    final request = (offset: offset, sessionId: sessionId, type: type);
    rankRequests.add(request);
    final result =
        await (rankReply?.call(request) ?? Future.value(_page(hasMore: false)));
    return RankListResult(
        offset: result.offset,
        sessionId: result.sessionId,
        count: result.count,
        hasMore: result.hasMore,
        nextOffset: result.nextOffset,
        list: result.list);
  }
}

HomePageResult _page({
  int offset = 0,
  int nextOffset = 17,
  String sessionId = '首页会话',
  bool hasMore = true,
  int start = 1,
  int size = 6,
  String name = '短剧',
}) =>
    HomePageResult(
      offset: offset,
      sessionId: sessionId,
      // 返回条数与上游分页游标无关，不能用列表长度或 count 猜下一页。
      count: 999,
      hasMore: hasMore,
      nextOffset: nextOffset,
      list: List.generate(
          size,
          (index) => Drama.fromJson({
                'id': start + index,
                'name': '$name${start + index}',
              })),
    );

void main() {
  late _FeedApi client;
  late DownloadService downloads;

  setUp(() {
    DeviceProfile.isTv = true;
    SharedPreferences.setMockInitialValues({});
    client = _FeedApi();
    downloads = DownloadService(
        apiClient: client,
        documentsDirectory: () async => Directory.systemTemp);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  tearDown(() {
    DeviceProfile.isTv = false;
    downloads.dispose();
    client.dio.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> openHome(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: HomePage(apiClient: client, downloadService: downloads),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  int gridItemCount(WidgetTester tester) => tester
      .widget<SliverGrid>(find.byType(SliverGrid).first)
      .delegate
      .estimatedChildCount!;

  Future<void> closeHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets('电视首页无需滚动沿真实会话和游标补到24条，达到目标后停止预取', (tester) async {
    const cursors = [17, 43, 91, 128];
    client.homeReply = (request) async {
      final index = client.homeRequests.length - 1;
      return _page(
        offset: request.offset ?? 0,
        nextOffset: cursors[index],
        sessionId: '会话$index',
        start: index * 6 + 1,
      );
    };
    await openHome(tester);
    expect(client.homeRequests.map((request) => request.offset),
        [null, 17, 43, 91]);
    expect(client.homeRequests.map((request) => request.sessionId),
        [null, '会话0', '会话1', '会话2']);
    expect(gridItemCount(tester), 24);
    await tester.pump(const Duration(seconds: 2));
    expect(client.homeRequests.length, 4);
    await closeHome(tester);
  });

  testWidgets('电视空页有新游标时继续衔接，无更多数据后停止', (tester) async {
    client.homeReply = (request) async {
      final index = client.homeRequests.length - 1;
      return _page(
        offset: request.offset ?? 0,
        nextOffset: (index + 1) * 17,
        start: index * 6 + 1,
        size: index == 1 ? 0 : 4,
        hasMore: index < 2,
      );
    };
    await openHome(tester);
    expect(client.homeRequests.length, 3);
    expect(gridItemCount(tester), 8);
    await closeHome(tester);
  });

  testWidgets('电视重复游标不再重发，保留此前成功加载的短剧', (tester) async {
    client.homeReply = (request) async => _page(
          offset: request.offset ?? 0,
          start: client.homeRequests.length * 6,
          nextOffset: 17,
        );
    await openHome(tester);
    expect(client.homeRequests.length, 2);
    expect(gridItemCount(tester), 12);
    await tester.pump(const Duration(seconds: 2));
    expect(client.homeRequests.length, 2);
    await closeHome(tester);
  });

  testWidgets('电视首屏最多请求6页，小批量回包也不会无限加载', (tester) async {
    client.homeReply = (request) async => _page(
          offset: request.offset ?? 0,
          start: client.homeRequests.length,
          size: 1,
          nextOffset: client.homeRequests.length * 17,
        );
    await openHome(tester);
    expect(client.homeRequests.length, 6);
    expect(gridItemCount(tester), 6);
    await tester.pump(const Duration(seconds: 2));
    expect(client.homeRequests.length, 6);
    await closeHome(tester);
  });

  testWidgets('电视补页失败不清空首批内容，不自动反复重试，可手动继续原游标', (tester) async {
    var fail = true;
    client.homeReply = (request) async {
      if (request.offset != null && fail) throw ApiException('网络暂不可用');
      return _page(
        offset: request.offset ?? 0,
        start: request.offset == null ? 1 : 7,
        hasMore: request.offset == null,
      );
    };
    await openHome(tester);
    expect(client.homeRequests.length, 2);
    expect(gridItemCount(tester), 6);
    await tester.pump(const Duration(seconds: 3));
    expect(client.homeRequests.length, 2);
    final retry = find.text('重试加载');
    await tester.ensureVisible(retry);
    await tester.pump(const Duration(milliseconds: 400));
    expect(client.homeRequests.length, 2);
    fail = false;
    Focus.of(tester.element(retry)).requestFocus();
    await tester.pump(const Duration(milliseconds: 400));
    expect(Focus.of(tester.element(retry)).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(client.homeRequests.length, 3);
    expect(client.homeRequests.last.offset, 17);
    expect(client.homeRequests.last.sessionId, '首页会话');
    expect(gridItemCount(tester), 12);
    await closeHome(tester);
  });

  testWidgets('电视榜单切换筛选后忽略上一筛选迟到的补页响应', (tester) async {
    final oldPage = Completer<HomePageResult>();
    client.rankReply = (request) {
      if (request.type == 'all' && request.offset != null) {
        return oldPage.future;
      }
      return Future.value(_page(
        offset: 0,
        name: request.type == 'male' ? '男频新结果' : '旧结果',
        start: request.type == 'male' ? 100 : 1,
        hasMore: request.type == 'all',
      ));
    };
    await openHome(tester);
    await tester.tap(find.text('推荐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(client.rankRequests.where((request) => request.type == 'all').length,
        2);
    await tester.tap(find.text('男频'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('男频新结果100'), findsOneWidget);
    oldPage.complete(_page(start: 500, name: '迟到旧结果'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('男频新结果100'), findsOneWidget);
    expect(find.textContaining('迟到旧结果'), findsNothing);
    expect(client.rankRequests.last.type, 'male');
    await closeHome(tester);
  });

  testWidgets('刷新废弃仍在途的首屏补页，旧响应不能污染新列表', (tester) async {
    final oldPage = Completer<HomePageResult>();
    var refreshed = false;
    client.homeReply = (request) {
      if (!refreshed && request.offset != null) return oldPage.future;
      return Future.value(_page(
        name: refreshed ? '刷新结果' : '原结果',
        start: refreshed ? 100 : 1,
        hasMore: !refreshed,
      ));
    };
    await openHome(tester);
    expect(client.homeRequests.length, 2);
    refreshed = true;
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator).first)
        .onRefresh();
    await tester.pump();
    expect(find.text('刷新结果100'), findsOneWidget);
    oldPage.complete(_page(start: 500, name: '刷新前迟到结果'));
    await tester.pump();
    expect(gridItemCount(tester), 6);
    expect(find.textContaining('刷新前迟到结果'), findsNothing);
    expect(client.homeRequests.last.offset, isNull);
    expect(client.homeRequests.last.sessionId, isNull);
    await closeHome(tester);
  });

  testWidgets('离开页面后迟到请求不会继续自动补页', (tester) async {
    final pending = Completer<HomePageResult>();
    client.homeReply = (_) => pending.future;
    await openHome(tester);
    await closeHome(tester);
    pending.complete(_page());
    await tester.pump();
    expect(client.homeRequests.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机首页仍然仅加载一页，不主动预取后续数据', (tester) async {
    DeviceProfile.isTv = false;
    client.homeReply = (_) async => _page();
    await openHome(tester);
    expect(client.homeRequests.length, 1);
    expect(gridItemCount(tester), 6);
    await closeHome(tester);
  });
}
