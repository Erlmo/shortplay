import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/native_player.dart';

const _channel = MethodChannel('shortplay/native_player');
const _eventChannel = MethodChannel('shortplay/native_player/events');
const _codec = StandardMethodCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var nextId = 100;

  Future<void> emit(int id, String type, Object value) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
        _eventChannel.name,
        _codec.encodeSuccessEnvelope(
            {'playerId': id, 'type': type, 'value': value}),
        (_) => done.complete());
    await done.future;
  }

  setUp(() {
    messenger.setMockMethodCallHandler(_eventChannel, (_) async => null);
  });
  tearDown(() async {
    await NativePlayer.resetEventListenerForTesting();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  testWidgets('本地播放器created和首帧事件早于create返回时仍能完成创建', (tester) async {
    final id = nextId++;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'create') {
        await emit(id, 'created', 42);
        await emit(id, 'firstFrame', true);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return {'playerId': id, 'textureId': -1};
      }
      return null;
    });
    final player = NativePlayer();
    var ready = false;
    unawaited(
        player.create('/cache/episode.mp4', '').then((_) => ready = true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
    try {
      expect(ready, isTrue);
      expect(player.textureId, 42);
      expect(player.firstFrameRendered, isTrue);
    } finally {
      await player.dispose();
    }
  });
  testWidgets('创建前收到本地文件错误时立即失败并释放实例', (tester) async {
    final id = nextId++;
    final released = <int>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'create') {
        await emit(id, 'error', 'ERROR_CODE_IO_FILE_NOT_FOUND');
        return {'playerId': id, 'textureId': -1};
      }
      if (call.method == 'dispose') released.add(call.arguments['id'] as int);
      return null;
    });
    final player = NativePlayer();
    await expectLater(player.create('/missing.mp4', ''),
        throwsA(predicate((e) => e.toString().contains('FILE_NOT_FOUND'))));
    expect(released, [id]);
  });

  testWidgets('创建后首帧前的解码错误立即结束等待', (tester) async {
    final id = nextId++;
    messenger.setMockMethodCallHandler(
        _channel,
        (call) async =>
            call.method == 'create' ? {'playerId': id, 'textureId': 42} : null);
    final player = NativePlayer();
    await player.create('/cache/video.mp4', '');
    final waiting = expectLater(player.waitForFirstFrame(),
        throwsA(predicate((e) => e.toString().contains('DECODING_FAILED'))));
    await emit(id, 'error', 'ERROR_CODE_DECODING_FAILED');
    await tester.pump();
    await waiting;
    await player.dispose();
  });

  testWidgets('开始等待首帧前已发生的错误仍能被读取', (tester) async {
    final id = nextId++;
    messenger.setMockMethodCallHandler(
        _channel,
        (call) async =>
            call.method == 'create' ? {'playerId': id, 'textureId': 42} : null);
    final player = NativePlayer();
    await player.create('/cache/video.mp4', '');
    await emit(id, 'error', '无法读取缓存');
    await expectLater(player.waitForFirstFrame(),
        throwsA(predicate((e) => e.toString().contains('无法读取缓存'))));
    await player.dispose();
  });

  testWidgets('没有created通知时限时失败并释放原生播放器', (tester) async {
    final id = nextId++;
    final released = <int>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'create') return {'playerId': id, 'textureId': -1};
      if (call.method == 'dispose') released.add(call.arguments['id'] as int);
      return null;
    });
    final player = NativePlayer();
    final waiting = expectLater(player.create('/cache/video.mp4', ''),
        throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await waiting;
    expect(released, [id]);
  });

  testWidgets('create应答超时后迟到的原生实例仍只释放一次', (tester) async {
    final id = nextId++;
    final response = Completer<Map<String, int>>();
    final released = <int>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'create') return response.future;
      if (call.method == 'dispose') released.add(call.arguments['id'] as int);
      return null;
    });
    final player = NativePlayer();
    final waiting = expectLater(player.create('/cache/video.mp4', ''),
        throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await waiting;
    response.complete({'playerId': id, 'textureId': -1});
    await tester.pump();
    await player.dispose();
    expect(released, [id]);
  });

  testWidgets('创建中退出不会向原生发送空id且能取消等待', (tester) async {
    final id = nextId++;
    final released = <int>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'create') return {'playerId': id, 'textureId': -1};
      expect(call.arguments['id'], isNotNull);
      if (call.method == 'dispose') released.add(call.arguments['id'] as int);
      return null;
    });
    final player = NativePlayer();
    final waiting = expectLater(
        player.create('/cache/video.mp4', ''), throwsA(isA<StateError>()));
    await tester.pump();
    await player.dispose();
    await waiting;
    await player.pause();
    expect(released, [id]);
  });
}
