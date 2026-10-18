import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/search_results.dart';
import 'package:shortplay/models/search_source.dart';
import 'package:shortplay/models/search_suggestion.dart';
import 'package:shortplay/pages/global_search_page.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/pages/search_results_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';

class _Adapter implements HttpClientAdapter {
  RequestOptions? request;
  Object payload = {'code': 0, 'data': _data('万妖')};
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    request = options;
    return ResponseBody.fromString(jsonEncode(payload), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object> _data(String query) => {
      'query_key': query,
      'use_rich': true,
      'query_result_v2': [
        {
          'name': '万妖图录传',
          'keyword': '123456',
          'show_type': 3,
          'search_high_light': {
            'text': '万妖图录传',
            'high_light_position': [
              [0, 2],
              [-1, 3],
              [2, 99]
            ]
          },
          'video_data': {
            'title': '万妖图录传',
            'video_detail': {'series_id': '123456'}
          },
          'can_play': true,
          'has_play_button': false,
        }
      ],
    };

class _Api extends ApiClient {
  final requests = <String, Completer<SearchSuggestionResult>>{};
  final queries = <String>[];
  final directoryRequests = <String>[];
  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) {
    directoryRequests.add(seriesId);
    return Completer<TheaterEpisodesResult>().future;
  }

  @override
  Future<SearchSuggestionResult> fetchSearchSuggestions(String keyword,
          {CancelToken? cancelToken,
          SearchSource source = SearchSource.comic}) =>
      (requests[keyword] = Completer<SearchSuggestionResult>()).future;
  @override
  Future<SearchResultsResponse> searchResults(SearchQuery query,
      {CancelToken? cancelToken}) async {
    queries.add(query.query);
    return const SearchResultsResponse(tabs: []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    DeviceProfile.isTv = false;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/native_player'), (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/native_player'), null);
  });

  test('联想请求保留自定义域名与端口，按key传参并解析富卡片与高亮', () async {
    final adapter = _Adapter();
    final api = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8765'))
          ..httpClientAdapter = adapter);
    addTearDown(() => api.dio.close(force: true));
    final result = await api.fetchSearchSuggestions(' 万妖 ');
    expect(adapter.request!.uri.toString(),
        'http://127.0.0.1:8765/nove/search/suggest?key=%E4%B8%87%E5%A6%96&source=hongguo_comic');
    expect(result.query, '万妖');
    final item = result.items.single;
    expect(item.name, '万妖图录传');
    expect(item.keyword, '123456');
    expect(item.drama!.id, 123456);
    expect(item.highlights.single.start, 0);
    expect(item.highlights.single.length, 2);
    expect(item.canPlay, isTrue);
    adapter.payload = {'code': 502, 'message': '联想暂不可用'};
    await expectLater(
        api.fetchSearchSuggestions('万妖'), throwsA(isA<ApiException>()));
  });

  test('普通关键词回退字符串，use_rich只控制上游展示标记', () {
    final plain = SearchSuggestionResult.fromJson({
      'query_key': 'WY',
      'query_result_v2': [],
      'query_result': ['万妖', '', null],
    });
    expect(plain.items.single.name, '万妖');
    final data = _data('WY')..['use_rich'] = false;
    final item = SearchSuggestionResult.fromJson(data).items.single;
    expect(item.isRich, isFalse);
    expect(item.canPlay, isFalse);
  });

  test('独立播放按钮只接受播放标记与明确视频ID，普通词条仍搜索', () {
    final rich = _data('WY');
    final row = (rich['query_result_v2'] as List).single as Map;
    row['can_play'] = false;
    row['has_play_button'] = true;
    rich['use_rich'] = false;
    expect(
        SearchSuggestionResult.fromJson(rich).items.single.drama?.id, 123456);
    final simple = SearchSuggestion.fromJson({
      'name': '万妖图录传第十三季',
      'keyword': '7690163276214176792',
      'word_type': 2,
      'show_type': 0,
      'can_play': true,
      'has_play_button': true,
    });
    expect(simple.drama, isNull);
    expect(simple.showPlayButton, isFalse);
    expect(SearchSuggestionResult.fromJson(rich).items.single.showPlayButton,
        isFalse);
    expect(SearchSuggestion.fromJson({'name': '2026', 'keyword': '2026'}).drama,
        isNull);
  });

  Future<void> open(WidgetTester tester, _Api api) async {
    await tester
        .pumpWidget(MaterialApp(home: GlobalSearchPage(apiClient: api)));
    await tester.pumpAndSettle();
  }

  testWidgets('手机联想忽略旧请求，点击词条搜索名称而非作品ID', (tester) async {
    final api = _Api();
    addTearDown(() => api.dio.close(force: true));
    await open(tester, api);
    await tester.enterText(find.byType(TextField), '万');
    await tester.pump(const Duration(milliseconds: 210));
    await tester.enterText(find.byType(TextField), '万妖');
    await tester.pump(const Duration(milliseconds: 210));
    api.requests['万妖']!
        .complete(const SearchSuggestionResult(query: '万妖', items: [
      SearchSuggestion(name: '万妖图录传', keyword: '123456'),
    ]));
    await tester.pump();
    api.requests['万']!.complete(const SearchSuggestionResult(
        query: '万', items: [SearchSuggestion(name: '旧结果')]));
    await tester.pumpAndSettle();
    expect(find.text('旧结果'), findsNothing);
    await tester.tap(find.text('万妖图录传'));
    await tester.pumpAndSettle();
    expect(api.queries, ['万妖图录传']);
    expect(find.byType(SearchResultsPage), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('global_search_history'), ['万妖图录传']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final type in ['卡片无播放标记', '卡片带独立播放按钮', '可播放且没有按钮', '仅作品ID的文字结果']) {
    testWidgets('手机联想$type点击整行正式搜索，保留名称与纠错入口', (tester) async {
      final api = _Api();
      addTearDown(() => api.dio.close(force: true));
      await open(tester, api);
      await tester.enterText(find.byType(TextField), '万妖');
      await tester.pump(const Duration(milliseconds: 210));
      final result = type == '仅作品ID的文字结果'
          ? SearchSuggestionResult.fromJson({
              'query_key': '万妖',
              'use_rich': true,
              'query_result_v2': [
                {
                  'name': '万妖图录传',
                  'keyword': '123456',
                  'word_type': 2,
                  'show_type': 0
                }
              ],
            })
          : SearchSuggestionResult.fromJson({
              ..._data('万妖'),
              'query_result_v2': [
                <String, dynamic>{
                  ...((_data('万妖')['query_result_v2'] as List).single as Map),
                  'can_play': type != '卡片无播放标记',
                  'has_play_button': type == '卡片带独立播放按钮',
                }
              ],
            });
      api.requests['万妖']!.complete(result);
      await tester.pumpAndSettle();
      await tester.tap(find.text('万妖图录传'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PlayerPage), findsNothing);
      expect(find.byType(SearchResultsPage), findsOneWidget);
      expect(api.queries, ['万妖图录传']);
      expect(api.directoryRequests, isEmpty);
      expect(
          tester
              .widget<SearchResultsPage>(find.byType(SearchResultsPage))
              .useCorrect,
          isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('global_search_history')!.first, '万妖图录传');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('手机只点独立播放按钮才直接播，整行入口不受按钮影响', (tester) async {
    final api = _Api();
    addTearDown(() => api.dio.close(force: true));
    await open(tester, api);
    await tester.enterText(find.byType(TextField), '万妖');
    await tester.pump(const Duration(milliseconds: 210));
    final raw = _data('万妖');
    ((raw['query_result_v2'] as List).single as Map)['has_play_button'] = true;
    api.requests['万妖']!.complete(SearchSuggestionResult.fromJson(raw));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('suggestion-play-123456')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(api.directoryRequests, ['123456']);
    expect(api.queries, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('清空、组词与离开页面均不会显示过期联想', (tester) async {
    final api = _Api();
    addTearDown(() => api.dio.close(force: true));
    await open(tester, api);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'wanyao',
      selection: TextSelection.collapsed(offset: 6),
      composing: TextRange(start: 0, end: 6),
    ));
    await tester.pump(const Duration(milliseconds: 250));
    expect(api.requests, isEmpty);
    await tester.enterText(find.byType(TextField), '万妖');
    await tester.pump(const Duration(milliseconds: 210));
    await tester.tap(find.byTooltip('清除'));
    api.requests['万妖']!.complete(SearchSuggestionResult.fromJson(_data('万妖')));
    await tester.pumpAndSettle();
    expect(find.text('万妖图录传'), findsNothing);
    await tester.enterText(find.byType(TextField), '离开');
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pumpWidget(const SizedBox.shrink());
    api.requests['离开']!.completeError(ApiException('网络失败'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('联想失败或返回关键词不匹配时仍可直接搜索', (tester) async {
    final api = _Api();
    addTearDown(() => api.dio.close(force: true));
    await open(tester, api);
    await tester.enterText(find.byType(TextField), 'WY');
    await tester.pump(const Duration(milliseconds: 210));
    api.requests['WY']!.complete(const SearchSuggestionResult(
        query: 'OLD', items: [SearchSuggestion(name: '旧结果')]));
    await tester.pumpAndSettle();
    expect(find.text('旧结果'), findsNothing);
    expect(find.text('联想暂不可用，仍可直接搜索'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.queries, ['WY']);
    expect(
        tester
            .widget<SearchResultsPage>(find.byType(SearchResultsPage))
            .useCorrect,
        isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
