import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('解析去重，LRU容量与过期检查', () async {
    var valid = true;
    var calls = 0;
    final cache =
        PlaybackResourceCache<String, int>(capacity: 2, isValid: (_) => valid);
    final loading = Completer<int>();
    final a = cache.load('a', () {
      calls++;
      return loading.future;
    });
    final b = cache.load('a', () async {
      calls++;
      return 99;
    });
    expect(identical(a, b), isTrue);
    loading.complete(1);
    expect(await a, 1);
    expect(calls, 1);
    await cache.load('b', () async => 2);
    expect(cache.get('a'), 1); // Touch A; B must be evicted next.
    await cache.load('c', () async => 3);
    expect(cache.get('b'), isNull);
    expect(cache.length, 2);
    valid = false;
    expect(cache.get('a'), isNull);
  });

  test('旧解析在清理后返回，不会覆盖新清晰度的结果', () async {
    final cache = PlaybackResourceCache<String, String>(
        capacity: 2, isValid: (_) => true);
    final old = Completer<String>();
    final pending = cache.load('video', () => old.future);
    cache.clear();
    expect(await cache.load('video', () async => 'new'), 'new');
    old.complete('old');
    expect(await pending, 'old');
    expect(cache.get('video'), 'new');
  });

  test('失败不写缓存，保留下一季首集且清除其他项', () async {
    final cache =
        PlaybackResourceCache<String, int>(capacity: 3, isValid: (_) => true);
    await expectLater(
        cache.load('failed', () async => throw StateError('fail')),
        throwsStateError);
    expect(await cache.load('failed', () async => 1), 1);
    await cache.load('next-season', () async => 2);
    cache.retainWhere((key) => key == 'next-season');
    expect(cache.get('failed'), isNull);
    expect(cache.get('next-season'), 2);
  });

  test('网络预取严格大于14秒触发，单队列只预渲染下一集', () async {
    final calls = <(int, PlaybackWork)>[];
    final gate = Completer<bool>();
    final session = PlaybackSession(run: (index, work, token) async {
      calls.add((index, work));
      if (index == 1) return gate.future;
      return true;
    });
    session.start(List.generate(5, (i) => PlaybackSource('$i')), 0);
    void update(int buffered) => session.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: Duration.zero,
        bufferedAhead: Duration(milliseconds: buffered));
    update(14000);
    await settle();
    expect(calls, isEmpty);
    update(14001);
    await settle();
    expect(calls, [(1, PlaybackWork.firstFrame)]);
    update(6000); // Between thresholds: keep the current job.
    gate.complete(true);
    await settle();
    await settle();
    expect(calls, [
      (1, PlaybackWork.firstFrame),
      (2, PlaybackWork.header),
      (3, PlaybackWork.header)
    ]);
    update(20000);
    await settle();
    expect(calls, hasLength(3));
    session.close();
  });

  test('缓冲低于5秒取消工作，恢复后同一任务可重试且取消不算失败', () async {
    final tokens = <PlaybackCancellation>[];
    final session = PlaybackSession(
      policy: const PlaybackPolicy(maxFailures: 1, preloadCount: 1),
      run: (_, __, token) async {
        tokens.add(token);
        await token.wait(Completer<void>().future);
        return true;
      },
    );
    session.start([const PlaybackSource('a'), const PlaybackSource('b')], 0);
    void update(int buffer) => session.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: Duration.zero,
        bufferedAhead: Duration(milliseconds: buffer));
    update(15000);
    await settle();
    update(5000);
    expect(tokens.first.isCancelled, isFalse);
    update(4999);
    await settle();
    expect(tokens.first.isCancelled, isTrue);
    update(14000);
    await settle();
    expect(tokens, hasLength(1));
    update(15000);
    await settle();
    expect(tokens, hasLength(2));
    session.close();
    await settle();
  });

  test('连续失败最多三次，不卡在队列里重试死循环', () async {
    var count = 0;
    final session = PlaybackSession(run: (_, __, ___) async {
      count++;
      return false;
    });
    session.start([const PlaybackSource('a'), const PlaybackSource('b')], 0);
    for (var i = 0; i < 8; i++) {
      session.update(
          firstFrame: true,
          buffering: false,
          active: true,
          played: Duration.zero,
          bufferedAhead: const Duration(seconds: 20));
      await settle();
    }
    expect(count, 3);
    session.close();
  });

  test('缓存下一集首帧立即准备，卡顿与后台不启动网络预取', () async {
    final calls = <int>[];
    final session = PlaybackSession(run: (index, _, __) async {
      calls.add(index);
      return true;
    });
    session.start([
      const PlaybackSource('a'),
      const PlaybackSource('b', local: true),
      const PlaybackSource('c')
    ], 0);
    session.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: Duration.zero,
        bufferedAhead: Duration.zero);
    await settle();
    expect(calls, [1]);
    session.update(
        firstFrame: true,
        buffering: true,
        active: true,
        played: const Duration(seconds: 10),
        bufferedAhead: const Duration(seconds: 20));
    await settle();
    expect(calls, [1]);
    session.update(
        firstFrame: true,
        buffering: false,
        active: false,
        played: const Duration(seconds: 10),
        bufferedAhead: const Duration(seconds: 20));
    await settle();
    expect(calls, [1]);
    session.close();
  });

  test('切集时取消旧任务，旧任务不阻止新会话准备首帧', () async {
    final calls = <int>[];
    final session = PlaybackSession(run: (index, _, token) async {
      calls.add(index);
      if (index == 1) await token.wait(Completer<void>().future);
      return true;
    });
    final sources = List.generate(4, (i) => PlaybackSource('$i'));
    void update() => session.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: Duration.zero,
        fullyBuffered: true);
    session.start(sources, 0);
    update();
    await settle();
    session.start(sources, 1);
    update();
    await settle();
    await settle();
    expect(calls, [1, 2, 3]);
    session.close();
  });

  test('当前缓冲不足时也取消本地下一集之后的网络头部任务', () async {
    PlaybackCancellation? header;
    final session = PlaybackSession(run: (index, work, token) async {
      if (work == PlaybackWork.header) {
        header = token;
        await token.wait(Completer<void>().future);
      }
      return true;
    });
    session.start([
      const PlaybackSource('a'),
      const PlaybackSource('b', local: true),
      const PlaybackSource('c')
    ], 0);
    session.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: Duration.zero,
        bufferedAhead: const Duration(seconds: 20));
    await settle();
    expect(header, isNotNull);
    session.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: Duration.zero,
        bufferedAhead: const Duration(seconds: 4));
    expect(header!.isCancelled, isTrue);
    await settle();
    session.close();
  });

  test('下一季预热排在窗口任务后，并共享串行与取消规则', () async {
    final order = <String>[];
    final gate = Completer<bool>();
    final session = PlaybackSession(run: (index, _, token) async {
      order.add('episode$index');
      return index == 1 ? gate.future : true;
    });
    session.start(List.generate(4, (i) => PlaybackSource('$i')), 0);
    session.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: Duration.zero,
        bufferedAhead: const Duration(seconds: 20));
    session.enqueue('next-season', (_) async {
      order.add('season');
      return true;
    });
    await settle();
    expect(order, ['episode1']);
    gate.complete(true);
    await settle();
    await settle();
    expect(order, ['episode1', 'episode2', 'episode3', 'season']);
    session.close();
  });

  test('首帧预渲染先静音，出画后暂停和停放；未出画不能返回就绪', () async {
    final order = <String>[];
    final frame = Completer<void>();
    final token = PlaybackCancellation();
    final preparing = prepareFirstFrame(
        cancellation: token,
        mute: () async => order.add('mute'),
        play: () async => order.add('play'),
        waitForFrame: () => frame.future,
        pause: () async => order.add('pause'),
        park: () async => order.add('park'));
    await settle();
    expect(order, ['mute', 'play']);
    frame.complete();
    await preparing;
    expect(order, ['mute', 'play', 'pause', 'park']);
  });

  test('等待首帧时可取消，取消后不会继续pause或发布就绪', () async {
    final token = PlaybackCancellation();
    var parked = false;
    final pending = prepareFirstFrame(
        cancellation: token,
        mute: () async {},
        play: () async {},
        waitForFrame: () => Completer<void>().future,
        pause: () async {},
        park: () async {
          parked = true;
        });
    final assertion = expectLater(pending, throwsA(isA<PlaybackCancelled>()));
    await settle();
    token.cancel();
    await assertion;
    expect(parked, isFalse);
  });
}
