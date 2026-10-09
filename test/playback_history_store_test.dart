import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/playback_record.dart';
import 'package:shortplay/services/playback_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('分享直达播放更新进度时保留已有封面和剧名', () async {
    await PlaybackHistoryStore.upsert(const PlaybackRecord(
      dramaId: 123,
      dramaName: '已有剧名',
      cover: 'https://example.com/cover.jpg',
      episodeIndex: 5,
      positionMs: 1000,
      updatedAtMs: 1,
    ));

    await PlaybackHistoryStore.upsert(const PlaybackRecord(
      dramaId: 123,
      dramaName: '分享短剧',
      cover: '',
      episodeIndex: 0,
      positionMs: 2000,
      updatedAtMs: 2,
    ));

    final records = await PlaybackHistoryStore.load();
    expect(records, hasLength(1));
    expect(records.single.dramaName, '已有剧名');
    expect(records.single.cover, 'https://example.com/cover.jpg');
    expect(records.single.episodeIndex, 0);
    expect(records.single.positionMs, 2000);
  });
}
