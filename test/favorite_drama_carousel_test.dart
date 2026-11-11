import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/settings_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/favorite_drama_store.dart';

void main() {
  testWidgets('收藏横向排列，左滑后能看到后面的剧集，横屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient();
    addTearDown(api.dispose);
    await tester.runAsync(() async {
      for (var i = 6; i >= 1; i--) {
        await FavoriteDramaStore.toggle(Drama(
            id: i,
            name: '收藏短剧$i',
            actors: '',
            cover: '',
            intro: '',
            tags: [],
            status: '',
            updateTime: '',
            isTheaterResource: true));
      }
    });
    await tester.pumpWidget(MaterialApp(home: SettingsPage(apiClient: api)));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(find.text('收藏短剧1').hitTestable(), findsOneWidget);
    expect(find.text('收藏短剧6').hitTestable(), findsNothing);
    await tester.drag(find.byKey(const ValueKey('favorite-drama-carousel')),
        const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('收藏短剧6').hitTestable(), findsOneWidget);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('设置最多展示10部，单行标题且无已收藏文字，全部入口展示所有收藏', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient();
    addTearDown(api.dispose);
    await tester.runAsync(() async {
      for (var i = 12; i >= 1; i--) {
        await FavoriteDramaStore.toggle(Drama(
            id: i,
            name: '收藏短剧$i',
            actors: '',
            cover: '',
            intro: '',
            tags: [],
            status: '',
            updateTime: '',
            isTheaterResource: true));
      }
    });
    await tester.pumpWidget(MaterialApp(home: SettingsPage(apiClient: api)));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    final carousel = tester.widget<ListView>(
        find.byKey(const ValueKey('favorite-drama-carousel')));
    expect(carousel.semanticChildCount, 10);
    expect(find.text('已收藏'), findsNothing);
    expect(tester.widget<Text>(find.text('收藏短剧1')).maxLines, 1);
    expect(await tester.runAsync(FavoriteDramaStore.load), hasLength(12));
    await tester.tap(find.text('全部'));
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(find.text('全部收藏'), findsOneWidget);
    final gridFinder = find.byKey(const ValueKey('all-favorite-dramas'));
    expect(
        tester
            .widget<GridView>(gridFinder)
            .childrenDelegate
            .estimatedChildCount,
        12);
    await tester.scrollUntilVisible(find.text('收藏短剧12'), 300,
        scrollable:
            find.descendant(of: gridFinder, matching: find.byType(Scrollable)));
    await tester.ensureVisible(find.text('收藏短剧12'));
    await tester.pumpAndSettle();
    expect(find.text('收藏短剧12').hitTestable(), findsOneWidget);
  });
}
