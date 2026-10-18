import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/search_results.dart';
import 'package:shortplay/pages/search_results_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';

Drama _drama(int id) => Drama(
      id: id,
      name: '测试剧$id',
      actors: '',
      cover: '',
      intro: '',
      tags: const [],
      status: '',
      updateTime: '',
    );

SearchResultsResponse _page({
  int count = 4,
  int firstId = 1,
  int type = 19,
  int nextOffset = 37,
  String passback = 'token +/%=&中文',
  bool hasMore = true,
  bool unsupported = false,
}) =>
    SearchResultsResponse(tabs: [
      SearchResultTab(
        type: type,
        title: type == 32 ? '漫剧' : '综合',
        groups: [
          if (unsupported)
            const SearchResultGroup(
              entries: [],
              showType: 612,
              raw: {'show_type': 612, 'cell_name': '暂不支持的卡片'},
            )
          else
            for (var index = 0; index < count; index++)
              SearchResultGroup(entries: [_drama(firstId + index)]),
        ],
        hasMore: hasMore,
        nextOffset: nextOffset,
        passback: passback,
        searchId: 'search +/%=id',
      ),
      if (type != 32) const SearchResultTab(type: 32, title: '漫剧', groups: []),
    ]);

class _PrefetchClient extends ApiClient {
  _PrefetchClient(this.handler);

  final Future<SearchResultsResponse> Function(SearchQuery query) handler;
  final requests = <SearchQuery>[];

  @override
  Future<SearchResultsResponse> searchResults(SearchQuery query,
      {CancelToken? cancelToken}) {
    requests.add(query);
    return handler(query);
  }
}

void main() {
  setUp(() => DeviceProfile.isTv = true);
  tearDown(() => DeviceProfile.isTv = false);

  Future<void> open(WidgetTester tester, _PrefetchClient client) async {
    addTearDown(() => client.dio.close(force: true));
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        MaterialApp(home: SearchResultsPage(keyword: '测试', apiClient: client)));
    await tester.pumpAndSettle();
  }

  testWidgets('TV首批四条会按上游游标连续补到二十四条', (tester) async {
    final client = _PrefetchClient((query) async {
      switch (query.offset) {
        case 0:
          return _page();
        case 37:
          return _page(
              count: 10, firstId: 5, nextOffset: 91, passback: '第二页 +/%=&');
        case 91:
          return _page(
              count: 10, firstId: 15, nextOffset: 143, passback: '第三页');
        default:
          throw StateError('不应提前请求第四页');
      }
    });
    await open(tester, client);
    expect(client.requests.map((query) => query.offset), [0, 37, 91]);
    expect(client.requests[1].passback, 'token +/%=&中文');
    expect(client.requests[1].searchId, 'search +/%=id');
    expect(client.requests[1].tabType, 19);
    expect(client.requests[2].passback, '第二页 +/%=&');
    expect(find.text('测试剧1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV不足二十四条但上游已经结束时停止补页', (tester) async {
    final client = _PrefetchClient((query) async =>
        query.offset == 0 ? _page() : _page(firstId: 5, hasMore: false));
    await open(tester, client);
    expect(client.requests, hasLength(2));
    expect(find.text('测试剧5'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV分页重复返回同一游标时停止避免重复请求', (tester) async {
    final client = _PrefetchClient(
        (query) async => query.offset == 0 ? _page() : _page(firstId: 5));
    await open(tester, client);
    expect(client.requests.map((query) => query.offset), [0, 37]);
    expect(find.text('测试剧5'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV首批只有不可展示卡片仍按hasMore自动读取下一页', (tester) async {
    final client = _PrefetchClient((query) async => query.offset == 0
        ? _page(unsupported: true)
        : _page(firstId: 5, hasMore: false));
    await open(tester, client);
    expect(client.requests.map((query) => query.offset), [0, 37]);
    expect(find.text('测试剧5'), findsOneWidget);
    expect(find.text('未找到相关内容'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('手机首次搜索仍只请求原首批结果', (tester) async {
    DeviceProfile.isTv = false;
    final client = _PrefetchClient((query) async => _page());
    await open(tester, client);
    expect(client.requests, hasLength(1));
    expect(find.text('测试剧1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV连续不可展示页自动最多读取六批并保留手动加载', (tester) async {
    final client = _PrefetchClient((query) async => _page(
        unsupported: true,
        nextOffset: query.offset + 9,
        passback: 'page-${query.offset + 9}'));
    await open(tester, client);
    expect(
        client.requests.map((query) => query.offset), [0, 9, 18, 27, 36, 45]);
    expect(find.byKey(const ValueKey('search-load-more')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV自动补页失败后停止且仍能手动重试', (tester) async {
    var failed = false;
    final client = _PrefetchClient((query) async {
      if (query.offset == 0) return _page();
      if (!failed) {
        failed = true;
        throw ApiException('模拟分页失败');
      }
      return _page(count: 20, firstId: 5, hasMore: false);
    });
    await open(tester, client);
    expect(client.requests, hasLength(2));
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('search-load-more')));
    await tester.tap(find.byKey(const ValueKey('search-load-more')));
    await tester.pumpAndSettle();
    expect(client.requests, hasLength(3));
    expect(client.requests.last.offset, 37);
    expect(find.text('加载失败，点击重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV切换筛选后忽略上一筛选未完成的补页响应', (tester) async {
    final oldPage = Completer<SearchResultsResponse>();
    final client = _PrefetchClient((query) async {
      if (query.tabType == 32) {
        return _page(type: 32, firstId: 501, count: 24, hasMore: false);
      }
      if (query.offset != 0) return oldPage.future;
      return _page();
    });
    addTearDown(() => client.dio.close(force: true));
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        MaterialApp(home: SearchResultsPage(keyword: '测试', apiClient: client)));
    // 旧分页故意保持pending，避免等待进度动画完全settle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(client.requests, hasLength(2));
    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    oldPage.complete(_page(firstId: 901, hasMore: true));
    await tester.pumpAndSettle();
    expect(client.requests, hasLength(3));
    expect(client.requests.last.tabType, 32);
    expect(find.text('测试剧501'), findsOneWidget);
    expect(find.text('测试剧901'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
