import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/widgets/danmaku_timeline.dart';

void main() {
  DanmakuTimeline timeline({int tracks = 2, int duration = 10000}) =>
      DanmakuTimeline(
        viewportWidth: 400,
        trackCount: tracks,
        durationMs: duration,
      );

  void tick(DanmakuTimeline engine, int media, int wall,
          {bool playing = true, double speed = 1}) =>
      engine.tick(
        positionMs: media,
        elapsed: Duration(milliseconds: wall),
        isPlaying: playing,
        playbackSpeed: speed,
      );

  void playUntil(DanmakuTimeline engine, int from, int to) {
    for (var t = from; t <= to; t += 16) {
      tick(engine, t, t);
    }
  }

  test('逐帧只取到期弹幕，成功入场从右侧开始并在当帧移动', () {
    final engine = timeline()
      ..setSource(const [
        DanmakuCue(id: 'zero', atMs: 0, width: 100),
        DanmakuCue(id: 'future', atMs: 5000, width: 100),
      ], positionMs: 0);
    tick(engine, 0, 0);
    final first = engine.placements.single;
    expect(first.cue.id, 'zero');
    expect(first.startMs, 0);
    expect(first.x, closeTo(399.2, 0.0001));
    playUntil(engine, 16, 4000);
    expect(engine.placements.single.x, closeTo(199.2, 0.0001));
    expect(engine.placements.any((p) => p.cue.id == 'future'), isFalse);
  });

  test('正常追加新批次保留正在滚动的对象、坐标及待排项', () {
    const a = DanmakuCue(id: 'a', atMs: 0, width: 100);
    const waiting = DanmakuCue(id: 'waiting', atMs: 0, width: 100);
    final engine = timeline(tracks: 1)
      ..setSource(const [a, waiting], positionMs: 0);
    playUntil(engine, 0, 1008);
    final active = engine.placements.single;
    final x = active.x;
    engine.setSource(const [
      a,
      waiting,
      DanmakuCue(id: 'next-batch', atMs: 5000, width: 100)
    ], positionMs: 1008);
    expect(identical(engine.placements.single, active), isTrue);
    expect(active.x, x);
    playUntil(engine, 1024, 3504);
    expect(engine.placements.any((p) => p.cue.id == 'waiting'), isTrue);
    expect(engine.placements.where((p) => p.cue.id == 'a').length, 1);
  });

  test('迟到历史数据不重算过去、不挤掉已经在屏幕上的弹幕', () {
    const activeCue = DanmakuCue(id: 'active', atMs: 0, width: 100);
    final engine = timeline()..setSource(const [activeCue], positionMs: 0);
    playUntil(engine, 0, 2000);
    final active = engine.placements.single;
    final x = active.x;
    engine.setSource([
      activeCue,
      ...List.generate(20,
          (i) => DanmakuCue(id: 'late-$i', atMs: 0, width: 100, weight: 100)),
      const DanmakuCue(id: 'new', atMs: 2016, width: 100),
    ], positionMs: 2000);
    tick(engine, 2016, 2016);
    expect(engine.placements.first, same(active));
    expect(active.x, closeTo(x - 0.8, 0.0001));
    expect(engine.placements.any((p) => p.cue.id.startsWith('late-')), isFalse);
    expect(engine.placements.any((p) => p.cue.id == 'new'), isTrue);
  });

  test('掉帧或媒体锚点前进不会把正在滚动的整屏弹幕瞬间移走', () {
    final engine = timeline()
      ..setSource(const [
        DanmakuCue(id: 'a', atMs: 0, width: 100),
      ], positionMs: 0);
    tick(engine, 0, 0);
    final active = engine.placements.single;
    final x = active.x;
    tick(engine, 12000, 12000);
    expect(engine.placements.single, same(active));
    expect(active.x, closeTo(x - 0.8, 0.0001));
  });

  test('已知到期项在本帧入轨，不按过去时间推算成已离屏', () {
    final engine = timeline()
      ..setSource(const [
        DanmakuCue(id: 'due', atMs: 1000, width: 100),
      ], positionMs: 0);
    tick(engine, 0, 0);
    tick(engine, 15000, 15000);
    expect(engine.placements.single.startMs, 15000);
    expect(engine.placements.single.x, closeTo(399.2, 0.0001));
  });

  test('暂停冻结在屏位置，恢复和倍速变化只影响后续运动', () {
    final engine = timeline()
      ..setSource(const [
        DanmakuCue(id: 'a', atMs: 0, width: 100),
      ], positionMs: 0);
    tick(engine, 0, 0);
    final active = engine.placements.single;
    final x = active.x;
    tick(engine, 0, 2000, playing: false);
    expect(active.x, x);
    tick(engine, 0, 2016, speed: 2);
    expect(active.x, closeTo(x - 1.6, 0.0001));
  });

  test('普通更新保留活动轨道，显式seek才清轨并重新定位到目标时间', () {
    const cues = [
      DanmakuCue(id: 'old', atMs: 0, width: 100),
      DanmakuCue(id: 'target', atMs: 5000, width: 100),
    ];
    final engine = timeline()..setSource(cues, positionMs: 0);
    tick(engine, 0, 0);
    expect(engine.placements.single.cue.id, 'old');
    engine.setSource(cues, positionMs: 5000, seek: true);
    expect(engine.placements, isEmpty);
    tick(engine, 5000, 1000);
    expect(engine.placements.single.cue.id, 'target');
    expect(engine.placements.single.x, closeTo(399.2, 0.0001));
  });

  test('未溢出时待排项超过四秒仍保留，新项导致拥堵时才清过期', () {
    const cues = [
      DanmakuCue(id: 'playing', atMs: 0, width: 100),
      DanmakuCue(id: 'waiting', atMs: 0, width: 100),
    ];
    final engine = timeline(tracks: 1, duration: 20000)
      ..setSource(cues, positionMs: 0);
    playUntil(engine, 0, 6000);
    final waiting = engine.placements.singleWhere((p) => p.cue.id == 'waiting');
    expect(waiting.startMs, greaterThan(4000));

    final congested = timeline(tracks: 1, duration: 20000)
      ..setSource([
        ...cues,
        ...List.generate(
            8, (i) => DanmakuCue(id: 'new$i', atMs: 5000, width: 100)),
      ], positionMs: 0);
    playUntil(congested, 0, 6000);
    expect(congested.placements.any((p) => p.cue.id == 'waiting'), isFalse);
  });

  test('队列溢出按最低权重淘汰，未淘汰项保留入队顺序', () {
    final engine = timeline(tracks: 10)
      ..setSource(
          List.generate(
              10,
              (i) => DanmakuCue(
                  id: '$i', atMs: 0, width: 10, weight: i.toDouble())),
          positionMs: 0);
    tick(engine, 0, 0);
    expect(engine.placements.map((p) => p.cue.id),
        ['2', '3', '4', '5', '6', '7', '8', '9']);
  });

  test('强插免容量和过期淘汰，仍等待轨道防碰撞', () {
    final force = timeline(tracks: 10)
      ..setSource(
          List.generate(
              9,
              (i) =>
                  DanmakuCue(id: '$i', atMs: 0, width: 10, forceInsert: true)),
          positionMs: 0);
    tick(force, 0, 0);
    expect(force.placements.length, 9);
    final waiting = timeline(tracks: 1, duration: 20000)
      ..setSource([
        const DanmakuCue(id: 'playing', atMs: 0, width: 100),
        const DanmakuCue(id: 'force', atMs: 0, width: 100, forceInsert: true),
        ...List.generate(
            8, (i) => DanmakuCue(id: 'new$i', atMs: 5000, width: 100)),
      ], positionMs: 0);
    playUntil(waiting, 0, 6000);
    expect(waiting.placements.singleWhere((p) => p.cue.id == 'force').startMs,
        greaterThan(4000));
  });

  test('后发长弹幕不能追尾，按轨道实际坐标判断入场', () {
    final engine = timeline(tracks: 1)
      ..setSource(const [
        DanmakuCue(id: 'short', atMs: 0, width: 40),
        DanmakuCue(id: 'long', atMs: 0, width: 400),
      ], positionMs: 0);
    int? longStart;
    for (var t = 0; t <= 10000; t += 16) {
      tick(engine, t, t);
      if (engine.placements.length < 2) continue;
      final front = engine.placements.first;
      final rear = engine.placements.last;
      longStart ??= rear.startMs;
      expect(
          rear.x - front.x - front.cue.width, greaterThanOrEqualTo(48 - 0.001));
    }
    expect(longStart, greaterThan(4000));
  });

  test('同时间同权重保持原始次序', () {
    final engine = timeline()
      ..setSource(const [
        DanmakuCue(id: 'b', atMs: 0, width: 20),
        DanmakuCue(id: 'a', atMs: 0, width: 20),
      ], positionMs: 0);
    tick(engine, 0, 0);
    expect(engine.placements.map((p) => p.cue.id), ['b', 'a']);
  });

  test('媒体钟用于到期取数，按锚点和倍速推进，暂停冻结并支持回拖', () {
    final clock = DanmakuMediaClock();
    double read(int position, int elapsed,
            {bool playing = true, double speed = 1}) =>
        clock.read(
            positionMs: position,
            elapsed: Duration(milliseconds: elapsed),
            isPlaying: playing,
            playbackSpeed: speed);
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
