import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/api_client.dart';

import 'support/video_resolution_adapter.dart';

void main() {
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
        api.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
    expect(adapter.requests, hasLength(1));
  });
}
