import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/expandable_synopsis.dart';

void main() {
  final longIntro = '少女误入万妖世界，与伙伴一起探寻身世，解开古老传说。' * 15;

  testWidgets('简介默认两行，可展开收起，新季简介恢复折叠', (tester) async {
    Widget page(String text) => MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 320, child: ExpandableSynopsis(text: text)))));
    await tester.pumpWidget(page(longIntro));
    Text synopsis() =>
        tester.widget<Text>(find.byKey(const ValueKey('synopsis-text')));
    expect(synopsis().maxLines, 2);
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(synopsis().maxLines, isNull);
    expect(find.text('收起'), findsOneWidget);
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(synopsis().maxLines, 2);
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page('另一季剧情：$longIntro'));
    await tester.pumpAndSettle();
    expect(synopsis().maxLines, 2);
    expect(find.text('展开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认展开配置支持手动收起，新季简介仍默认展开', (tester) async {
    Widget page(String text) => MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
          child: ExpandableSynopsis(
              text: text, initiallyExpanded: true, showHeading: false),
        )));
    await tester.pumpWidget(page(longIntro));
    Text synopsis() =>
        tester.widget<Text>(find.byKey(const ValueKey('synopsis-text')));
    expect(synopsis().maxLines, isNull);
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(synopsis().maxLines, 2);
    await tester.pumpWidget(page('下一季：$longIntro'));
    await tester.pumpAndSettle();
    expect(synopsis().maxLines, isNull);
    expect(find.text('收起'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短简介不出现多余的展开按钮', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 320, child: ExpandableSynopsis(text: '少女的奇幻旅程。')))));
    expect(find.text('展开'), findsNothing);
    expect(find.byKey(const ValueKey('synopsis-toggle')), findsNothing);
  });

  testWidgets('电视用确认键展开简介', (tester) async {
    DeviceProfile.isTv = true;
    addTearDown(() => DeviceProfile.isTv = false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 400, child: ExpandableSynopsis(text: longIntro)))));
    Focus.of(tester.element(find.text('展开'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('synopsis-text')))
            .maxLines,
        isNull);
    expect(tester.takeException(), isNull);
  });
}
