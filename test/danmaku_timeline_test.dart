import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/widgets/danmaku_timeline.dart';

void main() {
  DanmakuTimeline timeline({int tracks = 2, int duration = 10000}) =>
      DanmakuTimeline(
        viewportWidth: 400,
        trackCount: tracks,
        durationMs: duration,
      );

  test('零时刻弹幕入场，迟到数据和跳转按媒体时间重建当前位置', () {
    final engine = timeline()
      ..layout(const [DanmakuCue(id: 'zero', atMs: 0, width: 100)]);
    final first = engine.placements.single;
    expect(first.startMs, 0);
    expect(first.xAt(4000, 400), 200);
    expect(first.visibleAt(4000, 400), isTrue);
    expect(first.visibleAt(11000, 400), isFalse);
    // 网络四秒后到达，同一时间轴结果完全相同，不从右边补发过时条目。
    final late = timeline()
      ..layout(const [DanmakuCue(id: 'zero', atMs: 0, width: 100)]);
    expect(late.placements.single.xAt(4000, 400), first.xAt(4000, 400));
    // 回拖也直接读取对应时刻，不依赖已触发 ID 集合。
    expect(first.xAt(1000, 400), 350);
  });

  test('未溢出时保留待排项，拥堵入队时才按四秒期限清理', () {
    final engine = timeline(tracks: 1, duration: 20000)
      ..layout(const [
        DanmakuCue(id: 'a', atMs: 0, width: 100),
        DanmakuCue(id: 'b', atMs: 0, width: 100),
      ]);
    expect(engine.placements.length, 2);
    expect(engine.placements.last.startMs, greaterThan(4000));
    final congested = timeline(tracks: 1, duration: 20000)
      ..layout([
        const DanmakuCue(id: 'playing', atMs: 0, width: 100),
        const DanmakuCue(id: 'expired', atMs: 0, width: 100),
        ...List.generate(
            8, (i) => DanmakuCue(id: 'new$i', atMs: 5000, width: 100)),
      ]);
    expect(congested.placements.any((p) => p.cue.id == 'expired'), isFalse);
  });

  test('空闲轨道按16毫秒步长入场，不生成随机速度', () {
    final engine = timeline()
      ..layout(const [DanmakuCue(id: 'a', atMs: 17, width: 100)]);
    expect(engine.placements.single.startMs, 32);
    expect(engine.placements.single.speed, 0.05);
  });

  test('前条尾部未退出前，后发长弹幕不能追尾', () {
    final engine = timeline(tracks: 1)
      ..layout(const [
        DanmakuCue(id: 'short', atMs: 0, width: 40),
        DanmakuCue(id: 'long', atMs: 0, width: 400),
      ]);
    // 后条更快时即使入口有空位也不提前放入，直到不会追尾。
    final first = engine.placements.first;
    final second = engine.placements.last;
    expect(second.startMs, greaterThan(4000));
    for (var t = second.startMs; t < 10000; t += 16) {
      final frontTail = first.xAt(t.toDouble(), 400) + first.cue.width;
      final rearHead = second.xAt(t.toDouble(), 400);
      expect(rearHead - frontTail, greaterThanOrEqualTo(48 - 0.001));
    }
  });

  test('拥堵项最多保留8个，淘汰最低权重并保留原入队顺序', () {
    final engine = timeline(tracks: 10)
      ..layout(List.generate(
        10,
        (i) => DanmakuCue(id: '$i', atMs: 0, width: 10, weight: i.toDouble()),
      ));
    expect(engine.placements.length, 8);
    expect(engine.placements.first.cue.id, '2');
    expect(engine.placements.last.cue.id, '9');
  });

  test('强插标记免容量/过期淘汰但仍遵循轨道碰撞', () {
    final force = timeline(tracks: 10)
      ..layout(List.generate(
        9,
        (i) => DanmakuCue(id: '$i', atMs: 0, width: 10, forceInsert: true),
      ));
    expect(force.placements.length, 9);
    final waiting = timeline(tracks: 1, duration: 20000)
      ..layout([
        const DanmakuCue(id: 'playing', atMs: 0, width: 100),
        const DanmakuCue(id: 'force', atMs: 0, width: 100, forceInsert: true),
        ...List.generate(
            8, (i) => DanmakuCue(id: 'new$i', atMs: 5000, width: 100)),
      ]);
    final kept = waiting.placements.singleWhere((p) => p.cue.id == 'force');
    expect(kept.startMs, greaterThan(4000));
  });

  test('相同时间/权重使用原始顺序，重复重排结果稳定', () {
    final engine = timeline()
      ..layout(const [
        DanmakuCue(id: 'b', atMs: 0, width: 20),
        DanmakuCue(id: 'a', atMs: 0, width: 20),
      ]);
    expect(engine.placements.map((p) => p.cue.id), ['b', 'a']);
  });

  test('媒体钟按APK锚点和倍速持续推进，暂停冻结并支持回拖', () {
    final clock = DanmakuMediaClock();
    double read(int position, int elapsed,
            {bool playing = true, double speed = 1}) =>
        clock.read(
          positionMs: position,
          elapsed: Duration(milliseconds: elapsed),
          isPlaying: playing,
          playbackSpeed: speed,
        );
    expect(read(0, 0), 0);
    expect(read(0, 100), 100);
    expect(read(200, 200), 200);
    expect(read(200, 300), 300);
    expect(read(200, 1000), 1000);
    expect(read(200, 1200, playing: false), 200);
    expect(read(200, 1800, playing: false), 200);
    clock.reset();
    expect(read(2000, 2000, speed: 2), 2000);
    expect(read(2000, 2100, speed: 2), 2200);
    clock.reset();
    expect(read(500, 2200), 500);
  });
}
