import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';

import 'support/video_resolution_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const playerChannel = MethodChannel('shortplay/native_player');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(playerChannel, null);
  });
  test('原生解码器确认支持BVC2时上报能力并保留BVC2档位', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            playerChannel, (call) async => call.method == 'supportsBvc2');
    final adapter = VideoResolutionAdapter(
        reply: (_) => resolutionJson(resolutionResponse(
            streams: [resolvedVideoStream(codec: 'bytevc2')])));
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    final streams = await api.fetchFqVideoModel('1234567890');
    expect(streams.single.isByteVc2, isTrue);
    expect(adapter.requests.single.data, {'video_id': '1234567890'});
    expect(adapter.requests.single.headers['X-Playback-Codecs'], 'bvc2');
  });
  test('明确未加密的视频直接播放，不调用密钥接口', () async {
    final stream = resolvedVideoStream(codec: 'bytevc1')
      ..['encrypted'] = false
      ..['decrypt_key'] = ''
      ..['spade_a'] = ''
      ..['kid'] = '';
    final adapter = VideoResolutionAdapter(
      reply: (_) => resolutionJson(resolutionResponse(streams: [stream])),
    );
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(apiClient: api);
    final url =
        await manager.resolvePlayUrl('7704303211292658712', episodeIndex: 7);
    expect(url, 'https://cdn.example.com/video.mp4');
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.uri.path, '/algorithm/video');
    final items = await api.fetchFqVideoModel('7704303211292658712');
    expect(items.single.isEncrypted, isFalse);
    manager.clear();
  });

  test('未明确声明明文时仍拒绝空密钥，标记冲突也不能绕过校验', () async {
    for (final explicitlyPlain in [false, true]) {
      final stream = resolvedVideoStream()..['decrypt_key'] = '';
      if (explicitlyPlain) stream['encrypted'] = false;
      final adapter = VideoResolutionAdapter(
        reply: (_) => resolutionJson(resolutionResponse(streams: [stream])),
      );
      final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(api.dispose);
      await expectLater(
          api.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
    }
  });

  test('直接使用服务端返回的兼容画质，不自行签名或补充上游请求', () async {
    final adapter = VideoResolutionAdapter(
        reply: (_) => resolutionJson(resolutionResponse(streams: [
              resolvedVideoStream(definition: '1080p', codec: 'bytevc1'),
              resolvedVideoStream(definition: '480p'),
            ])));
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    final list = await api.fetchFqVideoModel('1234567890');
    expect(list.map((s) => s.definition), ['1080p', '480p']);
    expect(list.first.posterUrl, 'https://cdn.example.com/poster.jpg');
    expect(list.first.decryptKey, matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(list.first.expiresAt, isNotNull);
    expect(adapter.requests, hasLength(1));
  });
  test('防御性丢弃ByteVC2、无效key和非网络地址，保留有效档位', () async {
    final streams = [
      resolvedVideoStream(codec: 'bytevc2'),
      resolvedVideoStream(codec: ' BVC2 '),
      resolvedVideoStream(codec: 'video/bytevc2.1'),
      resolvedVideoStream()..['gear_des_key'] = 'normal_720p_ByteVC2',
      {
        ...resolvedVideoStream(codec: 'bvc2'),
        'video_meta': {'definition': '720p'},
      },
      resolvedVideoStream()..['decrypt_key'] = 'bad',
      resolvedVideoStream(url: 'file:///private/test'),
      resolvedVideoStream(definition: '360p')
    ];
    final adapter = VideoResolutionAdapter(
        reply: (_) => resolutionJson(resolutionResponse(streams: streams)));
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    expect(
        (await api.fetchFqVideoModel('1234567890')).single.definition, '360p');
    expect(adapter.requests, hasLength(1));
  });
  test('没有有效档位时明确失败，不直连任何备用上游', () async {
    final adapter = VideoResolutionAdapter(
        reply: (_) => resolutionJson(
            resolutionResponse(streams: [resolvedVideoStream(codec: 'bvc2')])));
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    await expectLater(
        api.fetchFqVideoModel('1234567890'),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('ByteVC2'))));
    expect(adapter.requests, hasLength(1));
  });
}
