import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/playback_record.dart';
import 'package:shortplay/pages/play_history_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/playback_history_store.dart';

PlaybackRecord record(int id) => PlaybackRecord(
    dramaId: id,
    dramaName: '短剧$id',
    cover: '',
    episodeIndex: 0,
    positionMs: 2000,
    updatedAtMs: 1000 + id);

Future<void> settle(WidgetTester tester) async {
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('批量删除只删除选中记录，串行写入不会丢失其他剧集', () async {
    await Future.wait(
        [for (var i = 1; i <= 3; i++) PlaybackHistoryStore.upsert(record(i))]);
    await Future.wait([
      PlaybackHistoryStore.removeRecords([
        PlaybackHistoryStore.recordKey(record(1)),
        PlaybackHistoryStore.recordKey(record(3))
      ]),
      PlaybackHistoryStore.upsert(record(4)),
    ]);
    expect((await PlaybackHistoryStore.load()).map((item) => item.dramaId),
        [4, 2]);
    await PlaybackHistoryStore.clear();
    expect(await PlaybackHistoryStore.load(), isEmpty);
  });

  testWidgets('管理模式支持单选、多选删除并保留全部清空', (tester) async {
    final api = ApiClient();
    addTearDown(api.dispose);
    await tester.runAsync(() async {
      for (var i = 1; i <= 3; i++) {
        await PlaybackHistoryStore.upsert(record(i));
      }
    });
    await tester.pumpWidget(MaterialApp(home: PlayHistoryPage(apiClient: api)));
    await settle(tester);
    expect(find.byTooltip('我的收藏'), findsNothing);
    await tester.tap(find.text('管理'));
    await settle(tester);
    await tester.tap(find.text('全选'));
    await settle(tester);
    expect(find.text('已选 3 条'), findsOneWidget);
    await tester.tap(find.text('取消全选'));
    await settle(tester);
    expect(find.text('已选 0 条'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect(await tester.runAsync(PlaybackHistoryStore.load), hasLength(3));
    await tester.tap(find.text('管理'));
    await settle(tester);
    await tester.tap(find.text('短剧1'));
    await tester.tap(find.text('短剧3'));
    await settle(tester);
    expect(find.text('已选 2 条'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settle(tester);
    expect(
        (await tester.runAsync(PlaybackHistoryStore.load))!.single.dramaId, 2);
    expect(find.text('短剧2'), findsOneWidget);
    await tester.tap(find.text('管理'));
    await settle(tester);
    await tester.tap(find.text('短剧2'));
    await settle(tester);
    await tester.tap(find.text('删除'));
    await settle(tester);
    expect(find.text('暂无播放记录'), findsOneWidget);
    await tester.runAsync(() => PlaybackHistoryStore.upsert(record(4)));
    await settle(tester);
    await tester.tap(find.text('清空'));
    await settle(tester);
    expect(await tester.runAsync(PlaybackHistoryStore.load), isEmpty);
  });
}
