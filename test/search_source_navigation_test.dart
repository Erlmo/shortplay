import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/search_results.dart';
import 'package:shortplay/models/search_source.dart';
import 'package:shortplay/models/search_suggestion.dart';
import 'package:shortplay/pages/global_search_page.dart';
import 'package:shortplay/pages/search_results_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';

class _SourceApi extends ApiClient {
  final requests = <SearchQuery>[];

  @override
  Future<SearchSuggestionResult> fetchSearchSuggestions(String keyword,
          {CancelToken? cancelToken,
          SearchSource source = SearchSource.comic}) async =>
      SearchSuggestionResult(query: keyword, items: [
        SearchSuggestion(
          name: '万妖图录传第十三季',
          keyword: '7690163276214176792',
          source: source,
          searchSourceId: 'sug#opaque+/%=13',
          clientExtra: '{"query":"万妖","season":13}',
        ),
      ]);

  @override
  Future<SearchResultsResponse> searchResults(SearchQuery query,
      {CancelToken? cancelToken}) async {
    requests.add(query);
    final groups = [
      SearchResultGroup(entries: [
        Drama(
          id: 7690163276214176792,
          name: '万妖图录传第十三季',
          actors: '',
          cover: '',
          intro: '',
          tags: const [],
          status: '',
          updateTime: '',
        ),
      ]),
    ];
    return SearchResultsResponse(source: query.source, tabs: [
      SearchResultTab(type: 19, title: '综合', groups: groups),
      SearchResultTab(type: 32, title: '漫剧', groups: groups),
      SearchResultTab(type: 11, title: '短剧', groups: groups),
      const SearchResultTab(type: 1, title: '小说', groups: []),
    ]);
  }
}

void main() {
  setUp(() {
    DeviceProfile.isTv = false;
    SharedPreferences.setMockInitialValues({});
  });

  test('同源分页保留联想入口和不透明游标，跨真人来源开启新会话', () {
    const query = SearchQuery(
      query: '万妖图录传第十三季',
      source: SearchSource.comic,
      clickedContent: 'auto',
      searchSourceId: 'sug# +/%=13',
      clientExtra: '{"season":13}',
      useCorrect: true,
    );
    final next = query.nextPage(const SearchResultTab(
      type: 19,
      title: '综合',
      groups: [],
      nextOffset: 37,
      passback: ' token +/%=&中文 ',
      searchId: 'comic-sid',
      correctedQuery: '万妖图录传第十三季',
    ));
    expect(next.source, SearchSource.comic);
    expect(next.offset, 37);
    expect(next.searchSourceId, query.searchSourceId);
    expect(next.clientExtra, query.clientExtra);
    expect(next.toQueryParameters()['passback'], ' token +/%=&中文 ');
    final live = next.forScope(const SearchScope('真人剧', 11,
        source: SearchSource.shortplay,
        selectedItems: 'content_type_short_play'));
    expect(live.query, query.query);
    expect(live.source, SearchSource.shortplay);
    expect(live.selectedItems, 'content_type_short_play');
    expect(live.offset, 0);
    expect(live.firstEnter, isTrue);
    expect(live.searchId, isNull);
    expect(live.passback, isNull);
    expect(live.correctedQuery, isNull);
    expect(live.searchSourceId, isNull);
    expect(live.clientExtra, isNull);
    expect(live.clickedContent, isNull);
    final comic = next.forScope(const SearchScope('漫剧', 32));
    expect(comic.searchSourceId, query.searchSourceId);
    expect(comic.clientExtra, isNull);
    expect(comic.offset, 0);
    expect(comic.firstEnter, isFalse);
  });

  testWidgets('选择第十三季保留完整片名与联想来源，不把keyword作为搜索词', (tester) async {
    final api = _SourceApi();
    addTearDown(() => api.dio.close(force: true));
    await tester
        .pumpWidget(MaterialApp(home: GlobalSearchPage(apiClient: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '万妖');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.tap(find.text('万妖图录传第十三季'));
    await tester.pumpAndSettle();
    final query = api.requests.single;
    expect(query.query, '万妖图录传第十三季');
    expect(query.source, SearchSource.comic);
    expect(query.clickedContent, 'auto');
    expect(query.searchSourceId, 'sug#opaque+/%=13');
    expect(query.clientExtra, '{"query":"万妖","season":13}');
    expect(query.useCorrect, isTrue);
    expect(find.byType(SearchResultsPage), findsOneWidget);
    expect(find.text('万妖图录传第十三季'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('真实漫剧标签切tab32，真人剧切旧来源，切回综合恢复漫剧来源', (tester) async {
    final api = _SourceApi();
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(
        MaterialApp(home: SearchResultsPage(keyword: '万妖', apiClient: api)));
    await tester.pumpAndSettle();
    expect(find.text('小说'), findsNothing);
    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    expect(api.requests.last.tabType, 32);
    expect(api.requests.last.source, SearchSource.comic);
    final live = find.text('真人剧');
    await tester.ensureVisible(live);
    await tester.tap(live);
    await tester.pumpAndSettle();
    expect(api.requests.last.source, SearchSource.shortplay);
    expect(api.requests.last.tabType, 11);
    expect(api.requests.last.selectedItems, 'content_type_short_play');
    expect(api.requests.last.offset, 0);
    await tester.ensureVisible(find.text('综合'));
    await tester.tap(find.text('综合'));
    await tester.pumpAndSettle();
    expect(api.requests.last.source, SearchSource.comic);
    expect(api.requests.last.tabType, 19);
    expect(api.requests.last.selectedItems, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
