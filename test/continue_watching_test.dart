import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/playback_record.dart';
import 'package:shortplay/pages/home/continue_watching_row.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/playback_history_store.dart';

PlaybackRecord _record(int id,
        {int episodeIndex = 0,
        int positionMs = 0,
        int? durationMs,
        int? episodeCount,
        int updatedAtMs = 1}) =>
    PlaybackRecord(
      dramaId: id,
      dramaName: '剧$id',
      cover: '',
      episodeIndex: episodeIndex,
      episodeNumber: episodeIndex + 1,
      positionMs: positionMs,
      durationMs: durationMs,
      episodeCount: episodeCount,
      updatedAtMs: updatedAtMs,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('播放记录保存时长和总集数，并能算出单集进度', () {
    final record = PlaybackRecord.fromJson(
        _record(1, positionMs: 30000, durationMs: 120000, episodeCount: 80)
            .toJson());
    expect(record.durationMs, 120000);
    expect(record.episodeCount, 80);
    expect(record.episodeProgress, closeTo(0.25, 1e-9));
    // 旧记录没有时长：不显示进度
    expect(
        PlaybackRecord.fromJson(_record(2).toJson()).episodeProgress, isNull);
  });

  test('同一集的进度更新沿用已知时长，并通知监听者', () async {
    var notified = 0;
    void listener() => notified++;
    PlaybackHistoryStore.revision.addListener(listener);
    addTearDown(() => PlaybackHistoryStore.revision.removeListener(listener));

    await PlaybackHistoryStore.upsert(
        _record(7, episodeIndex: 3, durationMs: 90000, episodeCount: 60));
    await PlaybackHistoryStore.upsert(
        _record(7, episodeIndex: 3, positionMs: 45000, updatedAtMs: 2));

    final saved = (await PlaybackHistoryStore.load()).single;
    expect(saved.positionMs, 45000);
    expect(saved.durationMs, 90000);
    expect(saved.episodeCount, 60);
    expect(notified, 2);
  });

  testWidgets('首页继续观看：有记录时显示，没记录时不占位，记录变化自动刷新', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContinueWatchingRow(
          apiClient: ApiClient(),
          onShowAll: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('继续观看'), findsNothing);
    expect(find.text('为你推荐'), findsNothing);

    await tester.runAsync(() => PlaybackHistoryStore.upsert(_record(9,
        episodeIndex: 4,
        positionMs: 30000,
        durationMs: 60000,
        episodeCount: 50)));
    await tester.pumpAndSettle();
    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.text('剧9'), findsOneWidget);
    expect(find.text('看到第5集 · 共50集'), findsOneWidget);
    final bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(0.5, 1e-9));
  });
}
