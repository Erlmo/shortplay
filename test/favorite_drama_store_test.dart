import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/settings_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/favorite_drama_store.dart';

Drama drama(int id, {bool theater = true}) => Drama(
      id: id,
      name: '短剧$id',
      actors: '',
      cover: '',
      intro: '简介',
      tags: ['漫剧'],
      status: '2',
      updateTime: '',
      isTheaterResource: theater,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('收藏保存剧集身份，取消收藏不影响其他剧集', () async {
    await FavoriteDramaStore.toggle(drama(1));
    await FavoriteDramaStore.toggle(drama(2, theater: false));
    final items = await FavoriteDramaStore.load();
    expect(items.map((item) => item.id), [2, 1]);
    expect(items.last.isTheaterResource, isTrue);
    expect(items.first.isTheaterResource, isFalse);
    expect(items.last.tags, ['漫剧']);
    expect(await FavoriteDramaStore.toggle(drama(1)), isFalse);
    expect((await FavoriteDramaStore.load()).single.id, 2);
  });

  test('并发收藏不互相覆盖，重复取消不会重新添加', () async {
    await Future.wait([
      FavoriteDramaStore.toggle(drama(1)),
      FavoriteDramaStore.toggle(drama(2))
    ]);
    expect(await FavoriteDramaStore.load(), hasLength(2));
    await Future.wait([
      FavoriteDramaStore.remove(drama(1)),
      FavoriteDramaStore.remove(drama(1))
    ]);
    expect((await FavoriteDramaStore.load()).single.id, 2);
  });
  testWidgets('收藏列表显示持久化短剧，取消后同步为空列表', (tester) async {
    final api = ApiClient();
    addTearDown(api.dispose);
    await tester.runAsync(() => FavoriteDramaStore.toggle(drama(1)));
    await tester.pumpWidget(MaterialApp(home: SettingsPage(apiClient: api)));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(find.text('短剧1'), findsOneWidget);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(find.text('还没有收藏，去短剧详情页收藏喜欢的剧吧'), findsOneWidget);
    expect(await tester.runAsync(FavoriteDramaStore.load), isEmpty);
  });
}
