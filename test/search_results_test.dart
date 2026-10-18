import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/drama_season.dart';
import 'package:shortplay/models/search_results.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/pages/search_results_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';

Drama drama(int id, [String? name]) => Drama(
      id: id,
      name: name ?? '剧$id',
      actors: '',
      cover: '',
      intro: '',
      tags: const [],
      status: '',
      updateTime: '',
      isTheaterResource: true,
    );
const scopes = [
  SearchScope('综合', 11),
  SearchScope('漫剧', 11, selectedItems: 'content_type_dynamic_comic'),
  SearchScope('短剧', 11, selectedItems: 'content_type_short_play'),
];
SearchResultsResponse page(List<Drama> dramas,
        {int offset = 0, String token = '', bool more = false}) =>
    SearchResultsResponse(tabs: [
      SearchResultTab(
          type: 11,
          title: '综合',
          groups: [
            for (final d in dramas) SearchResultGroup(entries: [d])
          ],
          scopes: scopes,
          nextOffset: offset,
          passback: token,
          searchId: 'sid',
          correctedQuery: '万妖',
          hasMore: more),
    ]);

class SearchClient extends ApiClient {
  Future<DramaSeasons> Function(String)? seasonHandler;
  final requests = <SearchQuery>[];
  final directoryRequests = <String>[];
  final seasonRequests = <String>[];
  Future<SearchResultsResponse> Function(SearchQuery)? handler;
  DramaSeasons seasons =
      const DramaSeasons(albumId: '', currentSeason: 0, seasons: []);
  @override
  Future<SearchResultsResponse> searchResults(SearchQuery query,
      {CancelToken? cancelToken}) {
    requests.add(query);
    return handler?.call(query) ??
        Future.value(page([drama(1001, '万妖图录传第一季')]));
  }

  @override
  Future<DramaSeasons> fetchDramaSeasons(String seriesId,
      {CancelToken? cancelToken}) async {
    seasonRequests.add(seriesId);
    return seasonHandler?.call(seriesId) ?? seasons;
  }

  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) {
    directoryRequests.add(seriesId);
    return Completer<TheaterEpisodesResult>().future;
  }
}

void main() {
  test('同IP模板保留原始数据，不被拍平成作品或自动转为系列卡', () {
    final response = SearchResultsResponse.fromJson({
      'selected_tab_idx': 0,
      'search_tabs': [
        {
          'tab_type': 11,
          'title': '综合',
          'next_offset': 37,
          'passback': ' token +/%=&中文 ',
          'search_id': 'sid:1',
          'corrected_query': ' 万妖 ',
          'has_more': true,
          'selector': {
            'rows': [
              {
                'type': 'content_type',
                'items': [
                  {'selector_item_id': 'content_type_dynamic_comic'},
                  {'selector_item_id': 'content_type_short_play'},
                ]
              }
            ]
          },
          'data': [
            {
              'show_type': 612,
              'cell_name': '其他版本',
              'lynx_data':
                  '{"cell_data":[{"video_data":[{"video_detail":{"series_id_str":"7628202881140657177","series_title":"第二季"}},{"video_detail":{"series_id":"7621200213801176126","series_title":"第一季"}}]}]}'
            },
          ],
        }
      ],
    });
    final tab = response.primaryTab!;
    expect(tab.scopes.map((scope) => scope.title), ['综合', '漫剧', '短剧']);
    expect(tab.groups.single.title, '其他版本');
    expect(tab.groups.single.entries, isEmpty);
    expect(tab.groups.single.seriesAlbums, isEmpty);
    expect(tab.groups.single.raw['lynx_data'], isNotNull);
    final next = const SearchQuery(
            query: '万妖',
            selectedItems: 'content_type_dynamic_comic',
            useCorrect: true)
        .nextPage(tab);
    expect(next.toQueryParameters(), {
      'query': '万妖',
      'source': 'hongguo_comic',
      'tab_type': 11,
      'selected_items': 'content_type_dynamic_comic',
      'offset': 37,
      'passback': ' token +/%=&中文 ',
      'search_id': 'sid:1',
      'corrected_query': ' 万妖 ',
      'use_correct': 'true',
      'is_first_enter_search': 'false',
    });
    final switched = next.forScope(scopes[2]);
    expect(switched.offset, 0);
    expect(switched.passback, isNull);
    expect(switched.searchId, isNull);
    expect(switched.selectedItems, 'content_type_short_play');
  });

  test('没有下发的内容筛选不伪造为上游分类', () {
    final tab =
        SearchResultTab.fromJson({'tab_type': 11, 'title': '综合', 'data': []});
    expect(tab.scopes.map((scope) => scope.title), ['综合']);
  });

  test('不透明游标不会因分隔符发生碰撞，顶层真实ID可作为详情ID缺失的回退', () {
    expect(
        const SearchQuery(
                query: 'q',
                tabType: 11,
                offset: 6,
                passback: 'a:b',
                searchId: 'c')
            .cursorKey,
        isNot(const SearchQuery(
                query: 'q',
                tabType: 11,
                offset: 6,
                passback: 'a',
                searchId: 'b:c')
            .cursorKey));
    final group = SearchResultGroup.fromJson({
      'show_type': 369,
      'video_data': [
        {
          'series_id': '7628202881140657177',
          'video_detail': {'series_title': '第二季'}
        }
      ]
    });
    expect(group.entries.single.id, 7628202881140657177);
  });

  test('完整搜索接口使用配置的地址并保持分类、游标与筛选原值', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://search.example.test:8443'));
    RequestOptions? request;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      request = options;
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'code': 0,
        'search_tabs': [
          {'tab_type': 11, 'title': '综合', 'data': []}
        ],
      }));
    }));
    final client = ApiClient(dio: dio);
    await client.searchResults(const SearchQuery(
        query: '万妖',
        tabType: 11,
        offset: 37,
        selectedItems: 'content_type_dynamic_comic',
        passback: ' +/%中文 ',
        searchId: 'sid'));
    expect(request!.uri.host, 'search.example.test');
    expect(request!.uri.port, 8443);
    expect(request!.uri.scheme, 'https');
    expect(request!.path, '/nove/search');
    expect(request!.uri.queryParameters['passback'], ' +/%中文 ');
    expect(request!.uri.queryParameters['selected_items'],
        'content_type_dynamic_comic');
    dio.close(force: true);
  });

  late SearchClient client;
  setUp(() {
    client = SearchClient();
    DeviceProfile.isTv = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/native_player'), (_) async => null);
  });
  tearDown(() {
    DeviceProfile.isTv = false;
    client.dio.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/native_player'), null);
  });
  Future<void> open(WidgetTester tester,
      {Size size = const Size(400, 900)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        MaterialApp(home: SearchResultsPage(keyword: '万妖', apiClient: client)));
    await tester.pumpAndSettle();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key,
      [int count = 1]) async {
    for (var i = 0; i < count; i++) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('综合漫剧短剧使用真实selected_items，切换清空本分类游标且不会被默认false重置',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    expect(client.requests.last.selectedItems, 'content_type_dynamic_comic');
    expect(client.requests.last.tabType, 11);
    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    expect(client.requests.last.selectedItems, 'content_type_short_play');
    expect(client.requests.last.offset, 0);
    expect(client.requests.last.searchId, isNull);
    await tester.tap(find.text('综合'));
    await tester.pumpAndSettle();
    expect(client.requests.last.selectedItems, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速切换范围，过期响应不能覆盖后一次搜索', (tester) async {
    final comic = Completer<SearchResultsResponse>();
    final short = Completer<SearchResultsResponse>();
    client.handler = (query) async {
      if (query.selectedItems == 'content_type_dynamic_comic') {
        return comic.future;
      }
      if (query.selectedItems == 'content_type_short_play') return short.future;
      return page([drama(1, '初始结果')]);
    };
    await open(tester);
    await tester.tap(find.text('漫剧'));
    await tester.pump();
    await tester.tap(find.text('短剧'));
    await tester.pump();
    short.complete(page([drama(3, '最新短剧')]));
    await tester.pumpAndSettle();
    comic.complete(page([drama(2, '过期漫剧')]));
    await tester.pumpAndSettle();
    expect(find.text('最新短剧'), findsOneWidget);
    expect(find.text('过期漫剧'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分页使用上游next_offset和不透明令牌，失败可以重试且停滞游标不循环请求', (tester) async {
    var nextCalls = 0;
    client.handler = (query) async {
      if (query.offset == 0) {
        return page([drama(1)], offset: 37, token: ' +/token ', more: true);
      }
      expect(query.offset, 37);
      expect(query.passback, ' +/token ');
      nextCalls++;
      if (nextCalls == 1) throw ApiException('离线');
      return page([drama(2)], offset: 37, token: ' +/token ', more: true);
    };
    await open(tester, size: const Size(600, 1200));
    await tester.tap(find.byKey(const ValueKey('search-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(nextCalls, 2);
    expect(find.text('已显示全部结果'), findsOneWidget);
    expect(find.text('剧2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('当前页没有视频时仍能沿真实游标继续加载后页', (tester) async {
    client.handler = (query) async => query.offset == 0
        ? page([], offset: 9, token: 'post-page', more: true)
        : page([drama(9, '后页短剧')]);
    await open(tester);
    expect(find.text('未找到相关内容'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('search-load-more')));
    await tester.pumpAndSettle();
    expect(client.requests.last.offset, 9);
    expect(client.requests.last.passback, 'post-page');
    expect(find.text('后页短剧'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通结果不查询季目录、不自动合并，也不丢掉其他cell里的相同作品', (tester) async {
    client.handler = (_) async => page([
          drama(1001, '万妖第一季'),
          drama(1002, '万妖第二季'),
          drama(1001, '同ID的另一个搜索卡'),
        ]);
    client.seasonHandler = (_) => throw StateError('普通搜索禁止额外查季目录');
    await open(tester, size: const Size(600, 1200));
    expect(client.seasonRequests, isEmpty);
    expect(find.text('万妖第一季'), findsOneWidget);
    expect(find.text('万妖第二季'), findsOneWidget);
    expect(find.text('同ID的另一个搜索卡'), findsOneWidget);
    expect(find.textContaining('共13季'), findsNothing);
    await tester.tap(find.text('万妖第二季'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.widget<PlayerPage>(find.byType(PlayerPage)).drama.id, 1002);
    expect(client.directoryRequests, ['1002']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('只有明确551/SeriesAlbum搜索卡显示各季，点击返回列表中的真实ID播放', (tester) async {
    Map<String, dynamic> video(int id, String title) => {
          'series_id': '$id',
          'title': title,
          'video_detail': {'series_id': '$id', 'series_title': title},
        };
    client.handler = (_) async => SearchResultsResponse.fromJson({
          'code': 0,
          'search_tabs': [
            {
              'tab_type': 11,
              'title': '综合',
              'data': [
                {
                  'show_type': 549,
                  'cell_data': [
                    {
                      'show_type': 550,
                      'cell_name': '系列剧',
                      'cell_data': [
                        {
                          'show_type': 551,
                          'search_ip_card_content_type': 24,
                          'video_data': [video(1002, '万妖图录传')],
                          'cell_data': [
                            for (var n = 1; n <= 13; n++)
                              {
                                'video_data': [video(1000 + n, '原始季名$n')],
                              }
                          ],
                        }
                      ],
                    }
                  ],
                }
              ],
            }
          ],
        });
    await open(tester);
    expect(client.seasonRequests, isEmpty);
    expect(find.textContaining('共13季'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('series-album-more-1002')));
    await tester.pumpAndSettle();
    final last = find.byKey(const ValueKey('series-album-item-playable:1013'));
    await tester.scrollUntilVisible(last, 300,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('series-album-panel-scroll')),
            matching: find.byType(Scrollable)));
    await tester.tap(last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.widget<PlayerPage>(find.byType(PlayerPage)).drama.id, 1013);
    expect(client.directoryRequests, ['1013']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV普通结果按返回顺序逐个可达，同ID焦点互不占用', (tester) async {
    DeviceProfile.isTv = true;
    client.handler = (_) async => page([
          drama(1001, '万妖第一季'),
          drama(1002, '万妖第二季'),
          drama(1001, '重复ID独立卡'),
        ]);
    await open(tester, size: const Size(960, 540));
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(Focus.of(tester.element(find.text('万妖第一季'))).hasFocus, isTrue);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(Focus.of(tester.element(find.text('万妖第二季'))).hasFocus, isTrue);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(Focus.of(tester.element(find.text('重复ID独立卡'))).hasFocus, isTrue);
    expect(client.seasonRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
