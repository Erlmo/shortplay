import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shortplay/models/playback_report_book.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/playback_report_queue.dart';
import 'package:shortplay/services/playback_report_session.dart';

import 'support/registered_device.dart';

class _FlakyQueuePreferences implements SharedPreferences {
  _FlakyQueuePreferences(this.delegate);

  final SharedPreferences delegate;
  bool failRemove = true;
  bool failWrite = false;

  @override
  Object? get(String key) => delegate.get(key);

  @override
  Future<bool> remove(String key) async =>
      failRemove ? false : delegate.remove(key);

  @override
  Future<bool> setString(String key, String value) async =>
      failWrite ? false : delegate.setString(key, value);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> add(
    PlaybackReportQueue queue, {
    String bookId = '123',
    String itemId = '456',
    int position = 1000,
    int delta = 1000,
    int index = 1,
    int timestamp = 10000,
  }) =>
      queue.checkpoint(
        bookId: bookId,
        itemId: itemId,
        positionMs: position,
        playedDeltaMs: delta,
        vidIndex: index,
        timestampMs: timestamp,
      );

  PlaybackReportQueue makeQueue({
    required Future<void> Function(List<PlaybackReportBook>, String) sender,
    Future<String?> Function()? owner,
    Future<String> Function()? verified,
    int Function()? timestampMs,
    void Function()? accepted,
  }) =>
      PlaybackReportQueue(
        sender: sender,
        currentOwner: owner ?? () async => 'device-A:install-A',
        verifiedOwner: verified ?? () async => 'device-A:install-A',
        timestampMs: timestampMs,
        onAccepted: accepted,
      );

  Future<Map<String, dynamic>> saved() async {
    final prefs = await SharedPreferences.getInstance();
    return jsonDecode(prefs.getString(PlaybackReportQueue.storageKey)!)
        as Map<String, dynamic>;
  }

  test('同剧跨集合并最新位置，并累计两集实际播放毫秒', () async {
    final sent = <PlaybackReportBook>[];
    final queue = makeQueue(sender: (books, owner) async => sent.addAll(books));
    await add(queue);
    await add(queue, itemId: '789', position: 2000, delta: 2000, index: 2);
    await queue.flush();
    expect(sent, hasLength(1));
    expect(sent.single.toJson(), {
      'book_id': '123',
      'item_id': '789',
      'book_type': 2,
      'current_play_time': 2000,
      'player_cumulative_total_duration': 3000,
      'read_timestamp_ms': 10000,
      'vid_index': 2,
      'is_listen_mode': false,
    });
    expect((await saved())['pending'], isEmpty);
    await add(queue, delta: 500);
    await queue.flush();
    expect(sent.last.cumulativeDuration, 3500);
  });

  test('失败保留持久队列，重启新实例后成功确认才删除', () async {
    final first =
        makeQueue(sender: (_, __) async => throw StateError('offline'));
    await add(first);
    await first.flush();
    expect((await saved())['pending'], hasLength(1));
    final restored = <PlaybackReportBook>[];
    final second =
        makeQueue(sender: (books, _) async => restored.addAll(books));
    await second.flush();
    expect(restored.single.cumulativeDuration, 1000);
    expect((await saved())['pending'], isEmpty);
  });

  test('超过50部按真实协议分批发送，不截掉剩余记录', () async {
    final sizes = <int>[];
    final queue =
        makeQueue(sender: (books, _) async => sizes.add(books.length));
    for (var id = 1; id <= 51; id++) {
      await add(queue, bookId: '$id');
    }
    await queue.flush();
    expect(sizes, [50, 1]);
    expect((await saved())['pending'], isEmpty);
  });

  test('旧请求成功时不会删除发送期间更新的新集进度', () async {
    final gate = Completer<void>();
    final sent = <PlaybackReportBook>[];
    var requests = 0;
    final queue = makeQueue(sender: (books, _) async {
      sent.addAll(books);
      if (++requests == 1) await gate.future;
    });
    await add(queue);
    final uploading = queue.flush();
    await Future<void>.delayed(Duration.zero);
    await add(queue, itemId: '789', index: 2, delta: 500);
    gate.complete();
    await uploading;
    expect((await saved())['pending'], hasLength(1));
    await queue.flush();
    expect(sent.map((book) => book.itemId), ['456', '789']);
    expect(sent.last.cumulativeDuration, 1500);
  });

  test('退出时flush遇到旧请求在途，旧请求结束后自动补发最新尾段一次', () async {
    final gate = Completer<void>();
    final sent = <PlaybackReportBook>[];
    final queue = makeQueue(sender: (books, _) async {
      sent.addAll(books);
      if (sent.length == 1) await gate.future;
    });
    await add(queue);
    final oldRequest = queue.flush();
    await Future<void>.delayed(Duration.zero);
    await add(queue, delta: 500, position: 1500);
    final closeRequest = queue.flush();
    gate.complete();
    await Future.wait([oldRequest, closeRequest]);
    await Future<void>.delayed(Duration.zero);
    expect(sent.map((book) => book.currentPlayTime), [1000, 1500]);
    expect(sent.last.cumulativeDuration, 1500);
    expect((await saved())['pending'], isEmpty);
  });

  test('失败退避且每轮只请求一次，显式唤醒可立即重试', () async {
    var now = 1000;
    var attempts = 0;
    final queue = makeQueue(
      timestampMs: () => now,
      sender: (_, __) async {
        attempts++;
        throw StateError('offline');
      },
    );
    await add(queue);
    await queue.flush();
    await queue.flush();
    expect(attempts, 1);
    now += 5000;
    await queue.flush();
    now += 5000;
    await queue.flush();
    expect(attempts, 2);
    await queue.flush(force: true);
    expect(attempts, 3);
  });

  test('注册设备更换后不把旧安装待发记录归给新设备', () async {
    final old = makeQueue(sender: (_, __) async {});
    await add(old);
    var sent = 0;
    final next = makeQueue(
      owner: () async => 'device-B:install-B',
      verified: () async => 'device-B:install-B',
      sender: (_, __) async => sent++,
    );
    await next.flush();
    expect(sent, 0);
    expect((await saved())['owner'], 'device-B:install-B');
    expect((await saved())['pending'], isEmpty);
  });

  test('首次离线观看尚未注册时可排队，首次身份确认后绑定并发送', () async {
    String? owner;
    final owners = <String>[];
    final queue = makeQueue(
      owner: () async => owner,
      verified: () async => owner = 'device-A:install-A',
      sender: (_, identity) async => owners.add(identity),
    );
    await add(queue);
    expect((await saved())['owner'], isNull);
    await queue.flush();
    expect(owners, ['device-A:install-A']);
  });

  test('发送期间更换身份，旧ACK不会删除新设备同剧记录', () async {
    var owner = 'device-A:install-A';
    var attempts = 0;
    final gate = Completer<void>();
    final queue = makeQueue(
      owner: () async => owner,
      verified: () async => owner,
      sender: (_, __) async {
        if (++attempts == 1) await gate.future;
      },
    );
    await add(queue);
    final pending = queue.flush();
    await Future<void>.delayed(Duration.zero);
    owner = 'device-B:install-B';
    await add(queue, delta: 500, itemId: '789');
    gate.complete();
    await pending;
    final state = await saved();
    expect(state['owner'], owner);
    expect(state['pending'], hasLength(1));
    expect(
        (state['pending'] as List).single['player_cumulative_total_duration'],
        500);
    await queue.flush();
    expect(attempts, 2);
  });

  test('损坏缓存清理失败不会永久锁住加载任务，存储恢复后可重试', () async {
    SharedPreferences.setMockInitialValues(
        {PlaybackReportQueue.storageKey: 123});
    final prefs = _FlakyQueuePreferences(await SharedPreferences.getInstance());
    final queue = PlaybackReportQueue(
      sender: (_, __) async {},
      currentOwner: () async => 'device-A:install-A',
      verifiedOwner: () async => 'device-A:install-A',
      preferencesLoader: () async => prefs,
    );
    await expectLater(add(queue), throwsA(isA<StateError>()));
    prefs.failRemove = false;
    await add(queue);
    await queue.flush();
    expect((await saved())['pending'], isEmpty);
  });

  test('旧集异步checkpoint晚返回时只补时长，不能盖掉新集位置', () async {
    final gate = Completer<String?>();
    var checks = 0;
    var delay = false;
    final sent = <PlaybackReportBook>[];
    final queue = makeQueue(
      owner: () {
        checks++;
        return delay && checks == 2
            ? gate.future
            : Future.value('device-A:install-A');
      },
      sender: (books, _) async => sent.addAll(books),
    );
    await add(queue, bookId: '999');
    await queue.flush();
    sent.clear();
    checks = 0;
    delay = true;
    final old = add(queue, itemId: '456', delta: 1000);
    await Future<void>.delayed(Duration.zero);
    await add(queue, itemId: '789', delta: 2000, index: 2, position: 8000);
    gate.complete('device-A:install-A');
    await old;
    await queue.flush();
    expect(sent.single.itemId, '789');
    expect(sent.single.currentPlayTime, 8000);
    expect(sent.single.cumulativeDuration, 3000);
  });

  for (final bad in <Object>[123, '{broken', '[]', '{}']) {
    test('损坏观看队列可清理后重新保存: $bad', () async {
      SharedPreferences.setMockInitialValues(
          {PlaybackReportQueue.storageKey: bad});
      final queue = makeQueue(sender: (_, __) async {});
      await add(queue);
      expect((await saved())['pending'], hasLength(1));
    });
  }

  test('二倍速按媒体进度累计，暂停缓冲后台不累计', () async {
    var now = Duration.zero;
    final sent = <PlaybackReportBook>[];
    final queue = makeQueue(sender: (books, _) async => sent.addAll(books));
    final session = PlaybackReportSession(
      bookId: '123',
      itemId: '456',
      vidIndex: 1,
      queue: queue,
      initialPositionMs: 0,
      elapsedTime: () => now,
      timestampMs: () => 10000,
    );
    void state(
        {bool playing = true, bool buffering = false, bool foreground = true}) {
      session.update(
          playing: playing,
          buffering: buffering,
          foreground: foreground,
          visible: true,
          seeking: false,
          rate: 2);
    }

    state();
    now += const Duration(seconds: 1);
    session.position(2000);
    state(playing: false);
    now += const Duration(seconds: 10);
    session.position(2000);
    state(buffering: true);
    now += const Duration(seconds: 10);
    session.position(2000);
    state(foreground: false);
    now += const Duration(seconds: 10);
    session.position(2000);
    state();
    now += const Duration(seconds: 1);
    session.position(4000);
    await session.checkpoint(close: true);
    await session.checkpoint(close: true);
    await queue.flush();
    expect(sent, hasLength(1));
    expect(sent.single.cumulativeDuration, 4000);
  });

  test('seek跨越90秒不记作观看，迟到首帧仍能恢复后续累计', () async {
    var now = Duration.zero;
    final sent = <PlaybackReportBook>[];
    final queue = makeQueue(sender: (books, _) async => sent.addAll(books));
    final session = PlaybackReportSession(
      bookId: '123',
      itemId: '456',
      vidIndex: 1,
      queue: queue,
      initialPositionMs: 0,
      elapsedTime: () => now,
      timestampMs: () => 10000,
    );
    session.update(
        playing: true,
        buffering: false,
        foreground: true,
        visible: true,
        seeking: false,
        rate: 1);
    now += const Duration(seconds: 1);
    session.position(1000);
    session.seek(90000);
    now += const Duration(seconds: 4);
    session.position(94000);
    now += const Duration(seconds: 1);
    session.position(95000);
    now += const Duration(seconds: 1);
    session.position(96000);
    await session.checkpoint();
    await queue.flush();
    expect(sent.single.currentPlayTime, 96000);
    expect(sent.single.cumulativeDuration, 2000);
  });

  for (final failure in ['preferences', 'owner', 'write']) {
    test('有效观看关闭后$failure首次失败，恢复发送仍不丢失也不重复累计', () async {
      var now = Duration.zero;
      var fail = true;
      final sent = <PlaybackReportBook>[];
      final prefs =
          _FlakyQueuePreferences(await SharedPreferences.getInstance())
            ..failWrite = failure == 'write';
      final queue = PlaybackReportQueue(
        sender: (books, _) async => sent.addAll(books),
        currentOwner: () async {
          if (failure == 'owner' && fail) throw StateError('read owner');
          return 'device-A:install-A';
        },
        verifiedOwner: () async => 'device-A:install-A',
        preferencesLoader: () async {
          if (failure == 'preferences' && fail) throw StateError('read prefs');
          return prefs;
        },
      );
      final session = PlaybackReportSession(
        bookId: '123',
        itemId: '456',
        vidIndex: 1,
        queue: queue,
        initialPositionMs: 0,
        elapsedTime: () => now,
        timestampMs: () => 10000,
      );
      session.update(
          playing: true,
          buffering: false,
          foreground: true,
          visible: true,
          seeking: false,
          rate: 1);
      now += const Duration(seconds: 1);
      session.position(1000);
      await expectLater(
          session.checkpoint(close: true), throwsA(isA<StateError>()));
      fail = false;
      prefs.failWrite = false;
      await queue.flush(force: true);
      await queue.flush(force: true);
      expect(sent, hasLength(1));
      expect(sent.single.cumulativeDuration, 1000);
      expect(sent.single.currentPlayTime, 1000);
    });
  }

  test('片尾已保存后原生先playing=false再completed，最终位置仍上报而不虚增时长', () async {
    var now = Duration.zero;
    final sent = <PlaybackReportBook>[];
    final queue = makeQueue(sender: (books, _) async => sent.addAll(books));
    final session = PlaybackReportSession(
      bookId: '123',
      itemId: '456',
      vidIndex: 1,
      queue: queue,
      initialPositionMs: 0,
      elapsedTime: () => now,
      timestampMs: () => 10000,
    );
    session.update(
        playing: true,
        buffering: false,
        foreground: true,
        visible: true,
        seeking: false,
        rate: 1);
    now += const Duration(milliseconds: 1500);
    session.position(1500);
    await session.checkpoint();
    await queue.flush();
    session.update(
        playing: false,
        buffering: false,
        foreground: true,
        visible: true,
        seeking: false,
        rate: 1);
    session.position(2000);
    await session.checkpoint(close: true);
    await queue.flush();
    expect(sent.map((book) => book.currentPlayTime), [1500, 2000]);
    expect(sent.last.cumulativeDuration, 1500);
  });

  test('上报API与其它API复用注册身份且只确认完整成功响应', () async {
    seedRegisteredDevice();
    final api = ApiClient(baseUrl: 'https://watch.test');
    addTearDown(() => api.dio.close(force: true));
    RequestOptions? request;
    var accepted = true;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      request = options;
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'code': 0,
        'data': {'accepted': accepted, 'count': 1, 'upload_timestamp': 123},
      }));
    }));
    const book = PlaybackReportBook(
        bookId: '123',
        itemId: '456',
        currentPlayTime: 1000,
        cumulativeDuration: 2000,
        readTimestampMs: 10000,
        vidIndex: 1);
    final owner =
        '${testRegisteredDevice['device_id']}:${testRegisteredDevice['install_id']}';
    await api.reportPlaybackBooks([book], owner);
    expect(request!.uri.path, '/nove/playback/report');
    expect(request!.method, 'POST');
    expect(request!.data, {
      'books': [book.toJson()],
      'write_mode': 1
    });
    expect(jsonDecode(request!.queryParameters['client_device'] as String),
        testRegisteredDevice);
    accepted = false;
    await expectLater(
        api.reportPlaybackBooks([book], owner), throwsA(isA<ApiException>()));
    await expectLater(api.reportPlaybackBooks([book], 'other-owner'),
        throwsA(isA<ApiException>()));
  });
}
