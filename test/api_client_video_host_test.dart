import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/config/api_config.dart';
import 'package:shortplay/services/api_client.dart';

class _VideoHostAdapter implements HttpClientAdapter {
  _VideoHostAdapter({
    this.primaryEmpty = true,
    this.fallbackEmpty = false,
    this.emptyContentType = Headers.jsonContentType,
    this.primaryBusinessError = false,
  });

  final bool primaryEmpty;
  final bool fallbackEmpty;
  final String emptyContentType;
  final bool primaryBusinessError;
  final List<RequestOptions> signRequests = [];
  final List<RequestOptions> videoRequests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == ApiConfig.algorithmSign) {
      signRequests.add(options);
      return _json({
        'code': 0,
        'data': {'x-test-signature': 'signature-${signRequests.length}'},
      });
    }
    if (options.uri.path != ApiConfig.fqVideoPath ||
        ![ApiConfig.fqVideoHost, ApiConfig.fqVideoFallbackHost]
            .contains(options.uri.host)) {
      throw StateError('未模拟的请求: ${options.uri}');
    }
    videoRequests.add(options);
    final primary = options.uri.host == ApiConfig.fqVideoHost;
    if (primary && primaryBusinessError) {
      return _json({'code': 403, 'message': '当前视频不可播放'});
    }
    if (primary ? primaryEmpty : fallbackEmpty) {
      return ResponseBody.fromString('', 200, headers: {
        Headers.contentTypeHeader: [emptyContentType],
      });
    }
    return _json({
      'code': 0,
      'data': {
        'video_model': jsonEncode({
          'video_list': [
            {
              'main_url': 'https://cdn.example.com/episode.mp4',
              'video_meta': {
                'definition': '720p',
                'codec_type': 'h264',
                'vwidth': 720,
                'vheight': 1280,
                'bitrate': 500000,
              },
              'encrypt_info': {'spade_a': 'test-spade', 'kid': 'test-kid'},
            }
          ],
        }),
      },
    });
  }

  ResponseBody _json(Map<String, Object> value) =>
      ResponseBody.fromString(jsonEncode(value), 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
}

ApiClient _client(_VideoHostAdapter adapter) {
  final client = ApiClient(dio: Dio()..httpClientAdapter = adapter);
  addTearDown(client.dispose);
  return client;
}

void _expectMatchingSignatures(_VideoHostAdapter adapter) {
  expect(adapter.signRequests, hasLength(adapter.videoRequests.length));
  for (final entry in adapter.videoRequests.indexed) {
    final video = entry.$2;
    final sign = adapter.signRequests[entry.$1];
    expect((sign.data as Map)['url'], video.uri.toString());
    expect(video.headers['Host'], video.uri.host);
    expect(video.headers['x-test-signature'], 'signature-${entry.$1 + 1}');
    final query = video.uri.queryParameters;
    final first = adapter.videoRequests.first.uri.queryParameters;
    expect(query['device_id'], matches(RegExp(r'^[1-9][0-9]{15}$')));
    expect(query['iid'], matches(RegExp(r'^[1-9][0-9]{18}$')));
    expect(query['device_id'], first['device_id']);
    expect(query['iid'], first['iid']);
    expect(query['cdid'], first['cdid']);
    expect(query['device_brand'], 'Xiaomi');
    expect(query['os_version'], '13');
    expect(query, isNot(contains('client_device')));
    expect(sign.queryParameters, isNot(contains('client_device')));
    expect(video.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')));
    expect(video.headers['user-agent'], ApiConfig.fqUserAgent);
  }
}

void main() {
  for (final contentType in [Headers.jsonContentType, 'text/plain']) {
    final responseType =
        contentType == Headers.jsonContentType ? 'null' : '空字符串';
    test('视频主域名HTTP 200返回$responseType时以本次临时参数重新签名备用域名', () async {
      final adapter = _VideoHostAdapter(emptyContentType: contentType);
      final items = await _client(adapter).fetchFqVideoModel('video-1');

      expect(items, hasLength(1));
      expect(items.single.url, 'https://cdn.example.com/episode.mp4');
      expect(adapter.videoRequests.map((request) => request.uri.host),
          [ApiConfig.fqVideoHost, ApiConfig.fqVideoFallbackHost]);
      final primary = adapter.videoRequests.first;
      final fallback = adapter.videoRequests.last;
      expect(fallback.uri.query, primary.uri.query);
      expect(fallback.uri.path, primary.uri.path);
      expect(fallback.method, primary.method);
      expect(fallback.data, primary.data);
      _expectMatchingSignatures(adapter);
    });
  }

  test('主域名视频有效时只签名和请求一次', () async {
    final adapter = _VideoHostAdapter(primaryEmpty: false);
    final items = await _client(adapter).fetchFqVideoModel('video-2');

    expect(items, hasLength(1));
    expect(adapter.videoRequests, hasLength(1));
    expect(adapter.videoRequests.single.uri.host, ApiConfig.fqVideoHost);
    _expectMatchingSignatures(adapter);
  });

  test('主备域名均返回空响应时终止并显示明确的服务异常', () async {
    final adapter = _VideoHostAdapter(fallbackEmpty: true);

    await expectLater(
      _client(adapter).fetchFqVideoModel('video-3'),
      throwsA(isA<ApiException>().having(
        (error) => error.message,
        'message',
        contains('视频服务暂时返回空数据'),
      )),
    );
    expect(adapter.videoRequests, hasLength(2));
    _expectMatchingSignatures(adapter);
  });

  test('视频接口明确返回业务错误时不切换域名重复请求', () async {
    final adapter = _VideoHostAdapter(primaryBusinessError: true);

    await expectLater(
      _client(adapter).fetchFqVideoModel('video-4'),
      throwsA(isA<ApiException>().having(
        (error) => error.message,
        'message',
        contains('当前视频不可播放'),
      )),
    );
    expect(adapter.videoRequests, hasLength(1));
    expect(adapter.videoRequests.single.uri.host, ApiConfig.fqVideoHost);
    _expectMatchingSignatures(adapter);
  });
}
