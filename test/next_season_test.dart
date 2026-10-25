import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/drama_season.dart';

const _seasons = DramaSeasons(albumId: 'album', currentSeason: 1, seasons: [
  DramaSeason(id: 11, title: '第一季', cover: '', order: 1, episodeCount: 50),
  DramaSeason(id: 22, title: '第二季', cover: '', order: 2, episodeCount: 60),
  DramaSeason(id: 33, title: '第三季', cover: '', order: 3, episodeCount: 70),
]);

void main() {
  test('本季之后按季序接下一季', () {
    expect(_seasons.nextAfter(11)?.id, 22);
    expect(_seasons.nextAfter(22)?.id, 33);
  });

  test('最后一季或不在列表中时没有下一季', () {
    expect(_seasons.nextAfter(33), isNull);
    expect(_seasons.nextAfter(99), isNull);
    expect(
      const DramaSeasons(albumId: '', currentSeason: 0, seasons: [])
          .nextAfter(11),
      isNull,
    );
  });
}
