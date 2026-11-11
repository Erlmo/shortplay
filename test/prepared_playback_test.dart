import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

class _Engine {
  bool usable = true;
}

PlaybackEngineKey key(String id, {int revision = 1, String quality = '720p'}) =>
    PlaybackEngineKey(id, revision: revision, variant: quality);

void main() {
  late PreparedPlaybackStore<_Engine> store;
  late List<_Engine> released;
  setUp(() {
    released = [];
    store = PreparedPlaybackStore(
        isUsable: (engine) => engine.usable, release: released.add);
  });
  test('首帧准备完成才发布，同一实例只交接一次，清理不释放已交接实例', () {
    final engine = _Engine();
    final ticket = store.begin(key('next'), PlaybackCancellation());
    expect(store.take(key('next')), isNull);
    expect(store.publish(ticket, engine), isTrue);
    expect(store.take(key('next')), same(engine));
    expect(store.take(key('next')), isNull);
    store.clear();
    expect(released, isEmpty);
  });
  test('切集后旧准备不能发布，即使原生迟到返回首帧', () {
    final old = store.begin(key('old'), PlaybackCancellation());
    final fresh = store.begin(key('new'), PlaybackCancellation());
    expect(old.cancellation.isCancelled, isTrue);
    expect(store.publish(old, _Engine()), isFalse);
    final engine = _Engine();
    expect(store.publish(fresh, engine), isTrue);
    store.finish(old);
    expect(store.take(key('new')), same(engine));
  });
  test('取消准备不释放已完成首帧，仍可交接给前台', () {
    final engine = _Engine();
    store.remember(key('ready'), engine);
    final ticket = store.begin(key('pending'), PlaybackCancellation());
    store.cancel();
    expect(store.publish(ticket, _Engine()), isFalse);
    expect(store.take(key('ready')), same(engine));
    expect(released, isEmpty);
  });
  test('后台出画后发生错误，交接时淘汰而非返回坏实例', () {
    final engine = _Engine();
    store.remember(key('next'), engine);
    engine.usable = false;
    expect(store.contains(key('next'), engine), isFalse);
    expect(store.take(key('next')), isNull);
    expect(released, [engine]);
  });
  test('同视频换画质或世代不会误复用', () {
    final engine = _Engine();
    store.remember(key('video'), engine);
    expect(store.take(key('video', quality: '1080p')), isNull);
    expect(store.take(key('video', revision: 2)), isNull);
    expect(store.take(key('video')), same(engine));
  });
  test('窗口容量受限，反向保留实例可转为下一集且只释放其余实例', () {
    final a = _Engine(), b = _Engine(), c = _Engine();
    store.remember(key('a'), a);
    store.remember(key('b'), b);
    expect(store.take(key('b')), same(b));
    store.remember(key('b'), b);
    store.remember(key('c'), c);
    expect(released, [a]);
    store.clear();
    expect(released, [a, b, c]);
  });
  test('准备命令不调用播放，真实首帧到达后才停放并发布', () async {
    final frame = Completer<void>();
    final calls = <String>[];
    final future = prepareFirstFrame(
      cancellation: PlaybackCancellation(),
      mute: () async => calls.add('mute'),
      prepare: () async => calls.add('prepare'),
      play: () async => calls.add('play'),
      waitForFrame: () => frame.future,
      pause: () async => calls.add('pause'),
      park: () async => calls.add('park'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['mute', 'prepare']);
    frame.complete();
    await future;
    expect(calls, ['mute', 'prepare', 'pause', 'park']);
  });
  test('同实例停放和激活不可交叉，失败后队列仍可执行', () async {
    final queue = PlaybackCommandQueue();
    final gate = Completer<void>();
    final calls = <String>[];
    final park = queue.run(() async {
      calls.add('park-start');
      await gate.future;
      calls.add('park-end');
      throw StateError('park failed');
    });
    final assertion = expectLater(park, throwsStateError);
    final activate = queue.run(() async => calls.add('activate'));
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['park-start']);
    gate.complete();
    await assertion;
    await activate;
    expect(calls, ['park-start', 'park-end', 'activate']);
  });
  test('快速反向切集取消旧激活，迟到定位不能继续解除静音和播放', () async {
    final token = PlaybackCancellation();
    final seek = Completer<void>();
    final calls = <String>[];
    final future = activatePreparedPlayback(
      cancellation: token,
      activate: () async => calls.add('activate'),
      position: () {
        calls.add('seek');
        return seek.future;
      },
      rate: () async => calls.add('rate'),
      unmute: () async => calls.add('unmute'),
      play: () async => calls.add('play'),
    );
    final assertion = expectLater(future, throwsA(isA<PlaybackCancelled>()));
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await assertion;
    seek.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['activate', 'seek']);
  });
  test('预载成功的下一集在当前出画后准备，不重复等待14秒且不放开后续网络任务', () async {
    final calls = <(int, PlaybackWork)>[];
    final session = PlaybackSession(
      isPreloaded: (i) => i == 1,
      run: (i, work, _) async {
        calls.add((i, work));
        return true;
      },
    );
    session.start(List.generate(4, (i) => PlaybackSource('$i')), 0);
    session.update(
        firstFrame: false,
        buffering: false,
        active: true,
        played: Duration.zero,
        bufferedAhead: Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    session.update(
        firstFrame: true,
        buffering: false,
        active: true,
        played: Duration.zero,
        bufferedAhead: Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(calls, [(1, PlaybackWork.firstFrame)]);
    session.close();
  });
}
