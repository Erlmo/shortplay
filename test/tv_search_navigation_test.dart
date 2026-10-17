import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/search_suggestion.dart';
import 'package:shortplay/pages/global_search_page.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/pages/search_results_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';

class _SearchApiClient extends ApiClient {
  final List<String> queries = [];
  final List<String> directoryRequests = [];
  bool direct = false;
  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) {
    directoryRequests.add(seriesId);
    return Completer<TheaterEpisodesResult>().future;
  }

  final List<String> suggestions = [];
  @override
  Future<SearchSuggestionResult> fetchSearchSuggestions(String keyword,
      {CancelToken? cancelToken}) async {
    suggestions.add(keyword);
    if (direct) {
      return SearchSuggestionResult(query: keyword, items: [
        SearchSuggestion.fromJson({
          'name': '万妖图录传',
          'keyword': '123456',
          'word_type': 2,
          'show_type': 0,
          'can_play': false
        }),
      ]);
    }
    return SearchSuggestionResult(query: keyword, items: const [
      SearchSuggestion(name: '万妖图录传', keyword: '123456'),
      SearchSuggestion(name: '万妖图录传第二季'),
    ]);
  }

  @override
  Future<({List<Drama> dramas, bool hasMore})> search(String keyword,
      {int offset = 0}) async {
    queries.add(keyword);
    return (dramas: <Drama>[], hasMore: false);
  }
}

void main() {
  late _SearchApiClient client;
  setUp(() {
    DeviceProfile.isTv = true;
    SharedPreferences.setMockInitialValues({
      'global_search_history': ['历史短剧一', '历史短剧二'],
    });
    client = _SearchApiClient();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/native_player'), (_) async => null);
  });
  tearDown(() {
    DeviceProfile.isTv = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('shortplay/native_player'), null);
    client.dio.close(force: true);
  });

  Future<void> openSearch(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester
        .pumpWidget(MaterialApp(home: GlobalSearchPage(apiClient: client)));
    await tester.pumpAndSettle();
  }

  Future<void> direction(WidgetTester tester, LogicalKeyboardKey key,
      [int times = 1]) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('电视默认聚焦A，不弹输入法，方向键与确认键输入字母', (tester) async {
    await openSearch(tester);
    expect(find.byType(TextField), findsNothing);
    expect(Focus.of(tester.element(find.text('A'))).hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    await direction(tester, LogicalKeyboardKey.arrowRight);
    await direction(tester, LogicalKeyboardKey.arrowDown);
    expect(Focus.of(tester.element(find.text('H'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.suggestions, ['H']);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('tv-search-query')),
            matching: find.text('H')),
        findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('电视WY联想可按右进入、按下选第二条、左回键盘并确认搜索', (tester) async {
    await openSearch(tester);
    await tester.tap(find.byKey(const ValueKey('tv-key-W')));
    await tester.tap(find.byKey(const ValueKey('tv-key-Y')));
    await tester.pumpAndSettle();
    expect(client.suggestions.last, 'WY');
    await direction(tester, LogicalKeyboardKey.arrowRight, 6);
    expect(Focus.of(tester.element(find.text('万妖图录传'))).hasFocus, isTrue);
    await direction(tester, LogicalKeyboardKey.arrowDown);
    expect(Focus.of(tester.element(find.text('万妖图录传第二季'))).hasFocus, isTrue);
    await direction(tester, LogicalKeyboardKey.arrowLeft);
    expect(Focus.of(tester.element(find.text('F'))).hasFocus, isTrue);
    await direction(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.queries, ['万妖图录传']);
    expect(find.byType(SearchResultsPage), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('global_search_history')!.first, '万妖图录传');
    Navigator.of(tester.element(find.byType(SearchResultsPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(GlobalSearchPage), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('电视遥控确认作品联想直接播放，不再进入搜索结果页', (tester) async {
    client.direct = true;
    await openSearch(tester);
    await tester.tap(find.byKey(const ValueKey('tv-key-W')));
    await tester.tap(find.byKey(const ValueKey('tv-key-Y')));
    await tester.pumpAndSettle();
    await direction(tester, LogicalKeyboardKey.arrowRight, 6);
    expect(Focus.of(tester.element(find.text('万妖图录传'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.byType(SearchResultsPage), findsNothing);
    expect(client.queries, isEmpty);
    expect(client.directoryRequests, ['123456']);
    expect(
        tester.widget<PlayerPage>(find.byType(PlayerPage)).initialEpisodeIndex,
        0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('电视键盘删除清空可达，空关键词确认不退出页面', (tester) async {
    await openSearch(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await direction(tester, LogicalKeyboardKey.arrowDown, 6);
    expect(Focus.of(tester.element(find.text('删除'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('历史记录'), findsOneWidget);
    await direction(tester, LogicalKeyboardKey.arrowRight);
    expect(Focus.of(tester.element(find.text('清空'))).hasFocus, isTrue);
    await direction(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(GlobalSearchPage), findsOneWidget);
    expect(client.queries, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('电视空输入可遥控选择历史，数字输入与清空后恢复历史', (tester) async {
    await openSearch(tester);
    await direction(tester, LogicalKeyboardKey.arrowRight, 6);
    expect(Focus.of(tester.element(find.text('历史短剧一'))).hasFocus, isTrue);
    await direction(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.queries, ['历史短剧二']);
    Navigator.of(tester.element(find.byType(SearchResultsPage))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-keyboard-1')));
    await tester.tap(find.byKey(const ValueKey('tv-key-1')));
    await tester.pumpAndSettle();
    expect(client.suggestions.last, '1');
    await tester.tap(find.byKey(const ValueKey('tv-keyboard-1')));
    await tester.pumpAndSettle();
    expect(find.text('历史记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('电视支持实体键盘字母和退格，手机仍使用系统输入法', (tester) async {
    await openSearch(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW, character: 'w');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY, character: 'y');
    await tester.pumpAndSettle();
    expect(client.suggestions.last, 'WY');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(client.suggestions.last, 'W');
    await tester.pumpWidget(const SizedBox.shrink());
    DeviceProfile.isTv = false;
    await tester
        .pumpWidget(MaterialApp(home: GlobalSearchPage(apiClient: client)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '手机短剧');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(client.queries, ['手机短剧']);
    expect(find.byType(SearchResultsPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
