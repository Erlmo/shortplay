import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/drama_detail_page.dart';
import 'package:shortplay/pages/settings_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/favorite_drama_store.dart';

Drama drama(int id) => Drama(
    id: id,
    name: '管理短剧$id',
    actors: '',
    cover: '',
    intro: '',
    tags: [],
    status: '',
    updateTime: '',
    isTheaterResource: true);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('批量取消只写入一次，并发新增不会被覆盖', () async {
    for (var i = 1; i <= 3; i++) {
      await FavoriteDramaStore.toggle(drama(i));
    }
    final revision = FavoriteDramaStore.revision.value;
    await FavoriteDramaStore.removeMany([
      FavoriteDramaStore.keyOf(drama(1)),
      FavoriteDramaStore.keyOf(drama(2))
    ]);
    expect(FavoriteDramaStore.revision.value, revision + 1);
    expect((await FavoriteDramaStore.load()).single.id, 3);
    await Future.wait([
      FavoriteDramaStore.removeMany([FavoriteDramaStore.keyOf(drama(3))]),
      FavoriteDramaStore.toggle(drama(4)),
    ]);
    expect((await FavoriteDramaStore.load()).single.id, 4);
  });

  testWidgets('全部收藏支持多选取消、全选、退出管理，设置页同步变化', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ApiClient();
    addTearDown(api.dispose);
    await tester.runAsync(() async {
      for (var i = 1; i <= 3; i++) {
        await FavoriteDramaStore.toggle(drama(i));
      }
    });
    await tester.pumpWidget(MaterialApp(home: SettingsPage(apiClient: api)));
    await settle(tester);
    await tester.tap(find.text('全部'));
    await settle(tester);
    await tester.tap(find.text('管理'));
    await settle(tester);
    await tester.tap(find.text('管理短剧1'));
    await tester.tap(find.text('管理短剧2'));
    await settle(tester);
    expect(find.byType(DramaDetailPage), findsNothing);
    expect(find.text('已选 2 部'), findsOneWidget);
    await tester.tap(find.text('取消收藏'));
    await settle(tester);
    expect((await tester.runAsync(FavoriteDramaStore.load))!.single.id, 3);
    await tester.tap(find.text('管理'));
    await settle(tester);
    await tester.tap(find.text('全选'));
    await settle(tester);
    expect(find.text('已选 1 部'), findsOneWidget);
    await tester.tap(find.text('取消全选'));
    await settle(tester);
    expect(find.text('已选 0 部'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect((await tester.runAsync(FavoriteDramaStore.load))!.single.id, 3);
    await tester.tap(find.text('管理'));
    await settle(tester);
    await tester.tap(find.text('全选'));
    await settle(tester);
    await tester.tap(find.text('取消收藏'));
    await settle(tester);
    expect(find.text('还没有收藏，去短剧详情页收藏喜欢的剧吧').hitTestable(), findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    expect(find.text('还没有收藏，去短剧详情页收藏喜欢的剧吧'), findsOneWidget);
    expect(await tester.runAsync(FavoriteDramaStore.load), isEmpty);
  });
}
