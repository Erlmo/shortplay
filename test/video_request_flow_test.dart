import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/video_request_executor.dart';

import 'support/video_resolution_adapter.dart';

Map<String, dynamic> execution(
        {String url =
            'https://configured-upstream.example/new-path?configured=1'}) =>
    {
      'protocol': 1,
      'action': 'request',
      'request_id': 'a' * 32,
      'expires_at': 4102444800,
      'expires_in_seconds': 45,
      'request': {
        'url': url,
        'method': 'POST',
        'headers': {
          'Content-Type': 'application/json',
          'x-server-signature': 'prepared-by-php'
        },
        'body': '{"server_defined":"unchanged bytes"}',
        'timeout_ms': 5000
      },
    };

class WireAdapter implements HttpClientAdapter {
  WireAdapter(this.reply);
  final ResponseBody Function(RequestOptions) reply;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('客户端原样执行服务端配置，隔离业务签名，再把原始响应交回PHP解析', () async {
    final bytes = [0, 255, 123, 34, 125]; // 不要求客户端理解上游响应格式。
    final upstream = WireAdapter((r) => ResponseBody.fromBytes(bytes, 200));
    final backend = WireAdapter((r) {
      if (r.uri.path == '/algorithm/videorequest') {
        expect(r.data, {'video_id': '1234567890'});
        return resolutionJson({'code': 0, 'data': execution()});
      }
      expect(r.uri.path, '/algorithm/videoresult');
      expect(r.data, {
        'request_id': 'a' * 32,
        'status_code': 200,
        'body_base64': base64Encode(bytes)
      });
      return resolutionJson(resolutionResponse());
    });
    final backendDio = Dio()..httpClientAdapter = backend;
    backendDio.interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
      r.headers['X-Dusa'] = 'backend-only';
      r.headers['Cookie'] = 'backend-only';
      h.next(r);
    }));
    final api = ApiClient(
        dio: backendDio,
        videoExecutor:
            VideoRequestExecutor(dio: Dio()..httpClientAdapter = upstream));
    addTearDown(api.dispose);
    final item = (await api.fetchFqVideoModel('1234567890')).single;
    final request = upstream.requests.single;
    expect(request.uri.toString(), execution()['request']['url']);
    expect(request.data, '{"server_defined":"unchanged bytes"}');
    expect(request.headers['x-server-signature'], 'prepared-by-php');
    expect(request.headers.containsKey('X-Dusa'), isFalse);
    expect(request.headers.containsKey('Cookie'), isFalse);
    expect(request.followRedirects, isFalse);
    expect(item.decryptKey, '0123456789abcdef0123456789abcdef');
    expect(await api.fetchDecryptKey(item.spadeA), item.decryptKey);
    expect(backend.requests, hasLength(2));
  });

  test('恢复和兼容补充按服务端返回的新请求执行，不在客户端猜参数', () async {
    var submissions = 0;
    final upstream = WireAdapter((r) => ResponseBody.fromString('opaque', 200));
    final backend = WireAdapter((r) {
      if (r.uri.path == '/algorithm/videoresult') {
        submissions++;
        if (submissions == 3) return resolutionJson(resolutionResponse());
      }
      return resolutionJson({
        'code': 0,
        'data': execution(
            url: 'https://configured-upstream.example/step-$submissions')
      });
    });
    final api = ApiClient(
        dio: Dio()..httpClientAdapter = backend,
        videoExecutor:
            VideoRequestExecutor(dio: Dio()..httpClientAdapter = upstream));
    addTearDown(api.dispose);
    expect(await api.fetchFqVideoModel('1234567890'), isNotEmpty);
    expect(upstream.requests.map((r) => r.uri.path),
        ['/step-0', '/step-1', '/step-2']);
  });

  test('上游失败和过大响应交给服务端决定，不把坏数据当播放结果', () async {
    for (final oversized in [false, true]) {
      final upstream = WireAdapter((r) => ResponseBody.fromBytes(
          oversized
              ? Uint8List(VideoRequestExecutor.maxResponseBytes + 1)
              : [1, 2],
          oversized ? 200 : 503));
      final backend = WireAdapter((r) {
        if (r.uri.path == '/algorithm/videorequest') {
          return resolutionJson({'code': 0, 'data': execution()});
        }
        final data = r.data as Map;
        if (oversized) {
          expect(data['error'], 'response_too_large');
          expect(data['body_base64'], '');
        } else {
          expect(data['status_code'], 503);
        }
        return resolutionJson({'code': 503, 'message': '上游暂不可用'}, status: 503);
      });
      final api = ApiClient(
          dio: Dio()..httpClientAdapter = backend,
          videoExecutor:
              VideoRequestExecutor(dio: Dio()..httpClientAdapter = upstream));
      try {
        await expectLater(
            api.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
      } finally {
        api.dispose();
      }
    }
  });

  test('不接受重定向到另一地址，由服务端处理状态', () async {
    final adapter =
        WireAdapter((r) => ResponseBody.fromString('', 302, headers: {
              'location': ['https://other.example/path']
            }));
    final executor =
        VideoRequestExecutor(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(executor.dispose);
    final result =
        await executor.execute(execution(), cancelToken: CancelToken());
    expect(result['status_code'], 302);
    expect(adapter.requests, hasLength(1));
  });

  for (final url in [
    'http://host.example/',
    'https://user:password@host.example/',
    'https://127.0.0.1/',
    'https://localhost/',
    'https://host.example:8443/'
  ]) {
    test('发网前拒绝不安全的请求地址 $url', () async {
      final adapter = WireAdapter((r) => throw StateError('不应发网'));
      final executor =
          VideoRequestExecutor(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(executor.dispose);
      await expectLater(
          executor.execute(execution(url: url), cancelToken: CancelToken()),
          throwsFormatException);
      expect(adapter.requests, isEmpty);
    });
  }

  test('过期请求发网前拒绝，错误协议不回退旧服务端解析', () async {
    for (final data in [
      execution()..['expires_in_seconds'] = 0,
      execution()..['protocol'] = 2
    ]) {
      final backend =
          WireAdapter((r) => resolutionJson({'code': 0, 'data': data}));
      final upstream = WireAdapter((r) => throw StateError('不应发网'));
      final api = ApiClient(
          dio: Dio()..httpClientAdapter = backend,
          videoExecutor:
              VideoRequestExecutor(dio: Dio()..httpClientAdapter = upstream));
      try {
        await expectLater(
            api.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
      } finally {
        api.dispose();
      }
      expect(upstream.requests, isEmpty);
      expect(backend.requests, hasLength(1));
    }
  });

  test('请求剩余时长由服务端决定，手机时钟偏差不误判配置过期', () async {
    final backend = WireAdapter((r) => r.uri.path == '/algorithm/videorequest'
        ? resolutionJson({'code': 0, 'data': execution()..['expires_at'] = 1})
        : resolutionJson(resolutionResponse()));
    final upstream = WireAdapter((r) => ResponseBody.fromString('opaque', 200));
    final api = ApiClient(
        dio: Dio()..httpClientAdapter = backend,
        clock: () => DateTime.utc(2050),
        videoExecutor:
            VideoRequestExecutor(dio: Dio()..httpClientAdapter = upstream));
    addTearDown(api.dispose);
    expect(await api.fetchFqVideoModel('1234567890'), isNotEmpty);
    expect(upstream.requests, hasLength(1));
  });

  test('服务端错误地持续下发请求时最多执行四次', () async {
    final backend =
        WireAdapter((r) => resolutionJson({'code': 0, 'data': execution()}));
    final upstream = WireAdapter((r) => ResponseBody.fromString('', 200));
    final api = ApiClient(
        dio: Dio()..httpClientAdapter = backend,
        videoExecutor:
            VideoRequestExecutor(dio: Dio()..httpClientAdapter = upstream));
    addTearDown(api.dispose);
    await expectLater(
        api.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
    expect(upstream.requests, hasLength(4));
  });
}
