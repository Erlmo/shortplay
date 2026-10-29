import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/liked_video_store.dart';
import 'package:shortplay/widgets/player/player_controls_overlay.dart';
import 'package:shortplay/widgets/danmaku_layer.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/services/native_player.dart';
import 'package:shortplay/services/playback_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const native = MethodChannel('shortplay/native_player');
  const events = MethodChannel('shortplay/native_player/events');
  const codec = StandardMethodCodec();

  Future<void> emit(String type, Object value) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope(
            {'playerId': 701, 'type': type, 'value': value}),
        (_) => done.complete());
    await done.future;
  }

  testWidgets('MP4 直连使用空解密密钥，播放退出不新增或改变短剧历史', (tester) async {
    SharedPreferences.setMockInitialValues({'playback_history_v1': '[]'});
    final before = (await SharedPreferences.getInstance())
        .getString('playback_history_v1');
    final revision = PlaybackHistoryStore.revision.value;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(
        SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      if (call.method == 'create') {
        await emit('created', 42);
        await emit('duration', 60000);
        await emit('firstFrame', true);
        return {'playerId': 701, 'textureId': -1};
      }
      if (call.method == 'play') await emit('playing', true);
      return null;
    });
    addTearDown(() async {
      await NativePlayer.resetEventListenerForTesting();
      messenger.setMockMethodCallHandler(native, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    const url = 'https://video.example/direct.mp4?tag=1';
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ApiClient();
    var requests = 0;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests++;
      handler.reject(DioException(requestOptions: options));
    }));
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage.direct(apiClient: api, url: url, title: '作者'),
    ));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(calls.where((call) => call.method == 'create'), hasLength(1),
        reason: 'calls: ${calls.map((c) => c.method).toList()}');
    expect(calls.singleWhere((call) => call.method == 'create').arguments,
        {'cdnUrl': url, 'keyHex': ''});
    expect(calls.any((call) => call.method == 'play'), isTrue);
    await emit('position', 30000);
    await tester.pump();
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.byType(PlayerControlsOverlay), findsOneWidget);
    expect(find.byType(DanmakuLayer), findsNothing);
    expect(find.text('选集'), findsNothing);
    expect(find.byTooltip('喜欢'), findsOneWidget);
    await tester.tap(find.byTooltip('喜欢'));
    await tester.pumpAndSettle();
    expect(await LikedVideoStore.contains(url), isTrue);
    expect(find.byTooltip('取消喜欢'), findsOneWidget);
    var overlay = tester
        .widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
    expect(overlay.positionMsNotifier.value, 30000);
    overlay.onSpeedChanged!(1.5);
    overlay.onSeekStart(20000);
    overlay.onSeekChanged(20000);
    overlay.onSeekEnd(20000);
    await tester.pump();
    expect(
        calls.any((call) =>
            call.method == 'seek' && call.arguments['positionMs'] == 20000),
        isTrue);
    expect(
        calls.any((call) =>
            call.method == 'setRate' && call.arguments['rate'] == 1.5),
        isTrue);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('弹幕'), findsNothing);
    expect(find.text('离线缓存'), findsNothing);
    expect(find.text('选集'), findsNothing);
    expect(find.text('倍速'), findsOneWidget);
    Navigator.of(tester.element(find.text('倍速'))).pop();
    await tester.pump(const Duration(milliseconds: 350));
    overlay = tester
        .widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
    overlay.onToggleLandscapeFullScreen();
    tester.view.physicalSize = const Size(844, 390);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('选集'), findsNothing);
    expect(find.byIcon(Icons.subtitles_rounded), findsNothing);
    expect(find.byIcon(Icons.subtitles_off_outlined), findsNothing);
    expect(find.textContaining('第1集'), findsNothing);
    expect(find.byTooltip('取消喜欢'), findsOneWidget);
    await tester.tap(find.byTooltip('取消喜欢'));
    await tester.pump();
    expect(await LikedVideoStore.contains(url), isFalse);
    expect(requests, 0, reason: 'MP4 不请求目录、解析、弹幕或其他短剧接口');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
        (await SharedPreferences.getInstance())
            .getString('playback_history_v1'),
        before);
    expect(PlaybackHistoryStore.revision.value, revision);
    expect(calls.any((call) => call.method == 'dispose'), isTrue);
    expect(tester.takeException(), isNull);
  });
}
