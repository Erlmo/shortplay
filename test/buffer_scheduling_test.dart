import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

void main() {
  test('卡顿停止预取，恢复到中间缓冲区不立即重启，重新超过14秒才恢复', () {
    final gate = PlaybackBufferGate();
    void update(int buffer, {bool stall = false, bool active = true}) =>
        gate.update(
            firstFrame: true,
            buffering: stall,
            active: active,
            played: const Duration(seconds: 10),
            bufferedAhead: Duration(milliseconds: buffer));
    update(14000);
    expect(gate.networkSafe, false);
    update(14001);
    expect(gate.networkSafe, true);
    update(5000);
    expect(gate.networkSafe, true);
    update(4999);
    expect(gate.networkSafe, false);
    update(15000);
    update(20000, stall: true);
    expect(gate.enabled, false);
    expect(gate.networkSafe, false);
    update(10000);
    expect(gate.enabled, true);
    expect(gate.networkSafe, false);
    update(14001);
    expect(gate.networkSafe, true);
  });
  test('尾端缓存按1秒容差判完整，未知或负缓冲不能冒充完整', () {
    bool end(int p, int total, int? buffer) =>
        PlaybackBufferGate.cacheReachesEnd(
            position: Duration(milliseconds: p),
            duration: Duration(milliseconds: total),
            bufferedAhead:
                buffer == null ? null : Duration(milliseconds: buffer));
    expect(end(5000, 20000, 13999), false);
    expect(end(5000, 20000, 14000), true);
    expect(end(20000, 0, 0), false);
    expect(end(20000, 20000, null), false);
    expect(end(20000, 20000, -1), false);
  });
  test('未知缓冲后端卡顿后必须重新实际前进3秒，停住等待不能算恢复', () {
    final gate = PlaybackBufferGate();
    void update(int played, {bool stall = false, bool active = true}) =>
        gate.update(
            firstFrame: true,
            buffering: stall,
            active: active,
            played: Duration(milliseconds: played));
    update(10000);
    expect(gate.networkSafe, true);
    update(10000, stall: true);
    for (var i = 0; i < 100; i++) {
      update(10000);
    }
    expect(gate.networkSafe, false);
    update(12999);
    expect(gate.networkSafe, false);
    update(13000);
    expect(gate.networkSafe, true);
    update(13000, active: false);
    update(13000);
    expect(gate.networkSafe, false);
    update(16000);
    expect(gate.networkSafe, true);
  });
  test('回退进度重置未知缓冲基线；暂停、首帧前和卡顿期间不得启动后台任务', () {
    final gate = PlaybackBufferGate();
    gate.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: const Duration(seconds: 10));
    gate.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: const Duration(seconds: 5));
    expect(gate.networkSafe, false);
    for (final first in [false, true]) {
      gate.update(
          firstFrame: first,
          buffering: false,
          active: false,
          played: const Duration(seconds: 30),
          fullyBuffered: true);
      expect(gate.enabled, false);
      expect(gate.networkSafe, false);
    }
  });
  test('卡顿取消的任务不消耗重试，缓冲恢复可从原队列重新启动', () async {
    final tokens = <PlaybackCancellation>[];
    final session = PlaybackSession(
      policy: const PlaybackPolicy(preloadCount: 1, maxFailures: 1),
      run: (_, __, token) async {
        tokens.add(token);
        await token.wait(Completer<void>().future);
        return true;
      },
    );
    session.start([const PlaybackSource('a'), const PlaybackSource('b')], 0);
    void update(int buffer, {bool stall = false}) => session.update(
        firstFrame: true,
        buffering: stall,
        active: true,
        played: Duration.zero,
        bufferedAhead: Duration(milliseconds: buffer));
    update(15000);
    await Future<void>.delayed(Duration.zero);
    update(0, stall: true);
    await Future<void>.delayed(Duration.zero);
    expect(tokens.single.isCancelled, true);
    update(6000);
    await Future<void>.delayed(Duration.zero);
    expect(tokens, hasLength(1));
    update(15000);
    await Future<void>.delayed(Duration.zero);
    expect(tokens, hasLength(2));
    session.close();
    await Future<void>.delayed(Duration.zero);
  });
  testWidgets('进度冻结时仍每300ms采样，停止后不再轮询', (tester) async {
    var polls = 0, samples = 0;
    final monitor = PlaybackBufferMonitor(
        read: () async {
          polls++;
        },
        onSample: () => samples++);
    monitor.start();
    await tester.pump();
    expect(polls, 1);
    await tester.pump(const Duration(milliseconds: 299));
    expect(polls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(polls, 2);
    expect(samples, 2);
    monitor.stop();
    await tester.pump(const Duration(seconds: 2));
    expect(polls, 2);
  });
  testWidgets('慢轮询不重叠，切集后迟到结果不触发恢复', (tester) async {
    final pending = Completer<void>();
    var reads = 0, samples = 0;
    final monitor = PlaybackBufferMonitor(
        read: () {
          reads++;
          return pending.future;
        },
        onSample: () => samples++);
    monitor.start();
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 1);
    monitor.stop();
    pending.complete();
    await tester.pump();
    expect(samples, 0);
  });
  testWidgets('采样错误不启动播放器，不终止后续缓存恢复检查', (tester) async {
    var polls = 0, errors = 0, samples = 0;
    final monitor = PlaybackBufferMonitor(
        read: () async {
          if (++polls == 1) throw StateError('query failed');
        },
        onSample: () => samples++,
        onError: (_, __) => errors++);
    monitor.start();
    await tester.pump();
    expect(errors, 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(samples, 1);
    monitor.stop();
  });
}
