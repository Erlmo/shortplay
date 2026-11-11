import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/api_client.dart';

import 'support/video_resolution_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('策略通过现有ApiClient取得真实协议，不追加到视频请求里', () async {
    final policy = jsonDecode(
        File('test/fixtures/playback_policy_73970.json').readAsStringSync());
    final adapter = VideoResolutionAdapter(
        reply: (request) => request.uri.path == '/algorithm/playbackpolicy'
            ? resolutionJson({'code': 0, 'data': policy})
            : resolutionJson(resolutionResponse()));
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    await api.playbackPolicies.refresh();
    expect(api.playbackPolicies.hasSettings, true);
    final videos = await api.fetchFqVideoModel('1234567890');
    expect(videos, hasLength(1));
    expect(adapter.requests.map((r) => r.uri.path),
        ['/algorithm/playbackpolicy', '/algorithm/video']);
    expect(adapter.requests.last.data, {'video_id': '1234567890'});
  });

  test('旧服务端404不影响原视频解析', () async {
    final adapter = VideoResolutionAdapter(
        reply: (request) => request.uri.path == '/algorithm/playbackpolicy'
            ? resolutionJson({'code': 404}, status: 404)
            : resolutionJson(resolutionResponse()));
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    await api.playbackPolicies.refresh();
    expect(api.playbackPolicies.hasSettings, false);
    expect(await api.fetchFqVideoModel('1234567890'), hasLength(1));
  });
}
