import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/services/playback_watch_clock.dart';

void main() {
  late Duration now;
  late PlaybackWatchClock clock;

  setUp(() {
    now = Duration.zero;
    clock = PlaybackWatchClock(elapsedTime: () => now);
  });

  void elapse(int milliseconds) {
    now += Duration(milliseconds: milliseconds);
  }

  test('预热播放器和未可见的视频不累计观看时长', () {
    clock.update(playing: true);
    elapse(30000);
    expect(clock.watched, Duration.zero);
    clock.update(visible: true);
    elapse(1200);
    expect(clock.watched, const Duration(milliseconds: 1200));
  });

  test('暂停和恢复只累计实际播放区间，多次读取不重复累计', () {
    clock.update(playing: true, visible: true);
    elapse(1600);
    clock.update(playing: false);
    elapse(30000);
    expect(clock.watched, const Duration(milliseconds: 1600));
    clock.update(playing: true);
    elapse(1400);
    expect(clock.watched, const Duration(seconds: 3));
    expect(clock.watched, const Duration(seconds: 3));
  });

  test('缓冲时即使原生仍报告playing也不累计', () {
    clock.update(playing: true, visible: true);
    elapse(800);
    clock.update(buffering: true);
    elapse(12000);
    clock.update(buffering: false);
    elapse(200);
    expect(clock.watched, const Duration(seconds: 1));
  });

  test('前后台与路由遮挡互相独立，恢复一个条件不会误计时', () {
    clock.update(playing: true, visible: true);
    elapse(1000);
    clock.update(foreground: false);
    elapse(9000);
    clock.update(visible: false);
    elapse(4000);
    clock.update(foreground: true);
    elapse(6000);
    expect(clock.watched, const Duration(seconds: 1));
    clock.update(visible: true);
    elapse(2000);
    expect(clock.watched, const Duration(seconds: 3));
  });

  test('拖动期间不累计，跳转位置不参与时长计算', () {
    clock.update(playing: true, visible: true);
    elapse(1000);
    clock.update(seeking: true);
    elapse(5000);
    clock.update(seeking: false);
    // 进度可以从 1 秒跳到 90 秒，观看计时只取真实经过的时间。
    elapse(1000);
    expect(clock.watched, const Duration(seconds: 2));
  });

  test('重复状态回调和同一时间内的快进不会增加时长', () {
    clock.update(playing: true, visible: true);
    elapse(1000);
    clock.update(playing: true);
    clock.update(playing: true, seeking: true);
    clock.update(seeking: false);
    expect(clock.watched, const Duration(seconds: 1));
    elapse(1000);
    expect(clock.watched, const Duration(seconds: 2));
  });

  test('在后台准备好的播放器直到前台可见才累计', () {
    clock.update(foreground: false);
    elapse(5000);
    clock.update(playing: true, visible: true);
    elapse(9000);
    expect(clock.watched, Duration.zero);
    clock.update(foreground: true);
    elapse(2000);
    expect(clock.watched, const Duration(seconds: 2));
  });
}
