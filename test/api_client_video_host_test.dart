import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/api_client.dart';

import 'support/video_resolution_adapter.dart';

void main() {
  test('客户端只向服务端提交视频ID取得播放结果，不执行上游请求', () async {
    final adapter = VideoResolutionAdapter();
    final client = ApiClient(
        dio: Dio()..httpClientAdapter = adapter,
        baseUrl: 'https://video-api.example:8443');
    addTearDown(client.dispose);
    final items = await client.fetchFqVideoModel('1234567890');
    expect(items.single.url, 'https://cdn.example.com/video.mp4');
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.uri.toString(),
        'https://video-api.example:8443/algorithm/video');
    expect(request.method, 'POST');
    expect(request.data, {'video_id': '1234567890'});
    expect(request.queryParameters, isEmpty);
    expect(request.headers, isNot(contains('x-ss-dp')));
  });
  for (final status in [404, 405]) {
    test('解析服务$status时提示更新服务端且不回退直连上游', () async {
      final adapter = VideoResolutionAdapter(
          reply: (_) => resolutionJson({'code': status}, status: status));
      final client = ApiClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(client.dispose);
      await expectLater(
          client.fetchFqVideoModel('1234567890'),
          throwsA(isA<ApiException>()
              .having((e) => e.code, 'status', status)
              .having((e) => e.message, 'message', contains('更新服务端'))));
      expect(adapter.requests, hasLength(1));
    });
  }
  for (final status in [502, 503]) {
    test('服务端$status错误保留可读提示，不在客户端循环重试', () async {
      final adapter = VideoResolutionAdapter(
          reply: (_) => resolutionJson({'code': status, 'message': '视频服务暂不可用'},
              status: status));
      final client = ApiClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(client.dispose);
      await expectLater(
          client.fetchFqVideoModel('1234567890'),
          throwsA(isA<ApiException>()
              .having((e) => e.message, 'message', '视频服务暂不可用')));
      expect(adapter.requests, hasLength(1));
    });
  }
  test('HTTP200业务失败不能当作解析成功', () async {
    final adapter = VideoResolutionAdapter(
        reply: (_) => resolutionJson({'code': 503, 'message': '视频服务返回空数据'}));
    final client = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(client.dispose);
    await expectLater(
        client.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
    expect(adapter.requests, hasLength(1));
  });
  for (final data in [
    null,
    <String, Object>{},
    {'streams': 'invalid'},
    {'streams': []}
  ]) {
    test('拒绝无效解析结构 $data', () async {
      final adapter = VideoResolutionAdapter(
          reply: (_) => resolutionJson({'code': 0, 'data': data}));
      final client = ApiClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(client.dispose);
      await expectLater(
          client.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
    });
  }
}
