import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/global_search_page.dart';
import 'package:shortplay/pages/search_results_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';

class _SearchApiClient extends ApiClient {
  final List<String> queries = [];

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
  });

  tearDown(() {
    DeviceProfile.isTv = false;
    client.dio.close(force: true);
  });

  Future<void> openSearch(WidgetTester tester) async {
    await tester
        .pumpWidget(MaterialApp(home: GlobalSearchPage(apiClient: client)));
    await tester.pumpAndSettle();
  }

  testWidgets('电视输入末尾按右键聚焦搜索，确认键发起搜索并保存历史', (tester) async {
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), '测试短剧');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('搜索'))).hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.queries, ['测试短剧']);
    expect(
        tester
            .widget<SearchResultsPage>(find.byType(SearchResultsPage))
            .keyword,
        '测试短剧');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('global_search_history')!.first, '测试短剧');
    expect(tester.takeException(), isNull);
  });

  testWidgets('电视从输入框按下可选择历史，左右移动并确认历史搜索', (tester) async {
    await openSearch(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('历史短剧一'))).hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('历史短剧二'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.queries, ['历史短剧二']);
    expect(
        tester
            .widget<SearchResultsPage>(find.byType(SearchResultsPage))
            .keyword,
        '历史短剧二');
    Navigator.of(tester.element(find.byType(SearchResultsPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(GlobalSearchPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('电视文本中间仍可编辑，搜索按钮按左回输入框、按下回历史', (tester) async {
    await openSearch(tester);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '测试短剧', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    var field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.selection.extentOffset, 2);
    field.controller!.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('搜索'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('历史短剧一'))).hasFocus, isTrue);
    expect(client.queries, isEmpty);
  });

  testWidgets('电视输入法组词时方向键不跳出输入框', (tester) async {
    await openSearch(tester);
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown
    ]) {
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: 'duanju',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 0, end: 6)));
      await tester.pump();
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue);
    }
    expect(client.queries, isEmpty);
  });

  testWidgets('电视没有历史时按下可到搜索，空关键词确认不退出页面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await openSearch(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('搜索'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(GlobalSearchPage), findsOneWidget);
    expect(client.queries, isEmpty);
  });

  testWidgets('手机输入框方向键保持编辑行为，输入法搜索仍可提交', (tester) async {
    DeviceProfile.isTv = false;
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), '手机短剧');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(client.queries, ['手机短剧']);
    expect(find.byType(SearchResultsPage), findsOneWidget);
  });
}
