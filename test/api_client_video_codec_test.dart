import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/config/api_config.dart';
import 'package:shortplay/services/api_client.dart';

class _VideoModelAdapter implements HttpClientAdapter {
  _VideoModelAdapter(this.videoList, this.legacyVideoList,
      {this.legacyFails = false, this.legacyGate});

  final Object videoList;
  final Object legacyVideoList;
  final bool legacyFails;
  final Future<void>? legacyGate;
  final List<String> signedUrls = [];
  final List<RequestOptions> videoRequests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final Map<String, Object> response;
    if (options.uri.path == ApiConfig.algorithmSign) {
      signedUrls.add((options.data as Map)['url'] as String);
      response = {
        'code': 0,
        'data': {'x-test-signature': 'signature-${signedUrls.length}'},
      };
    } else if (options.uri.host == ApiConfig.fqVideoHost &&
        options.uri.path == ApiConfig.fqVideoPath) {
      videoRequests.add(options);
      final legacy =
          !options.uri.queryParameters.containsKey('update_version_code');
      if (legacy && legacyGate != null) await legacyGate;
      response = legacy && legacyFails
          ? {'code': -1, 'message': '旧参数请求失败'}
          : {
              'code': 0,
              'data': {
                'video_model': jsonEncode({
                  'video_list': legacy ? legacyVideoList : videoList,
                  'poster_url': 'https://example.com/poster.jpg',
                }),
              },
            };
    } else {
      throw StateError('未模拟的请求: ${options.uri}');
    }
    return ResponseBody.fromString(jsonEncode(response), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object> _entry(
    String definition, String codec, bool nested, String source) {
  final url = 'https://example.com/$source/$definition-$codec.mp4';
  final meta = {
    'definition': definition,
    'codec_type': codec,
    'vwidth': 1080,
    'vheight': 1920,
    'bitrate': 500000,
  };
  const encryption = {'spade_a': 'test-spade', 'kid': 'test-kid'};
  return nested
      ? {'main_url': url, 'video_meta': meta, 'encrypt_info': encryption}
      : {
          'main_url': base64Encode(utf8.encode(url)),
          ...meta,
          ...encryption,
        };
}

Object _videoList(bool nested, List<(String, String)> streams, String source) {
  final entries = streams
      .map((stream) => _entry(stream.$1, stream.$2, nested, source))
      .toList();
  return nested
      ? entries
      : {
          for (final entry in entries.indexed) 'video_${entry.$1}': entry.$2,
        };
}

(ApiClient, _VideoModelAdapter) _client(
  bool nested,
  List<(String, String)> streams, {
  List<(String, String)> legacyStreams = const [],
  bool legacyFails = false,
  Future<void>? legacyGate,
}) {
  final adapter = _VideoModelAdapter(
    _videoList(nested, streams, 'current'),
    _videoList(nested, legacyStreams, 'legacy'),
    legacyFails: legacyFails,
    legacyGate: legacyGate,
  );
  final dio = Dio()..httpClientAdapter = adapter;
  addTearDown(() => dio.close(force: true));
  return (ApiClient(dio: dio), adapter);
}

void _expectIndependentlySignedRequests(_VideoModelAdapter adapter, int count) {
  expect(adapter.videoRequests, hasLength(count));
  expect(adapter.signedUrls,
      adapter.videoRequests.map((request) => request.uri.toString()));
  for (final request in adapter.videoRequests.indexed) {
    expect(
        request.$2.headers['x-test-signature'], 'signature-${request.$1 + 1}');
  }
  expect(adapter.videoRequests.first.uri.queryParameters['update_version_code'],
      '72132');
  if (count == 2) {
    expect(adapter.videoRequests.last.uri.queryParameters,
        isNot(contains('update_version_code')));
  }
}

void main() {
  testWidgets('兼容补充请求挂起时及时返回已有 1080P，不耗尽调用方十秒期限', (tester) async {
    final gate = Completer<void>();
    final (client, adapter) = _client(
        false,
        [
          ('720p', 'bytevc2'),
          ('1080p', 'bytevc1'),
        ],
        legacyStreams: [
          ('720p', 'bytevc1'),
        ],
        legacyGate: gate.future);
    List<String>? definitions;
    Object? failure;
    final completion = client
        .fetchFqVideoModel('7600755504016526398')
        .timeout(const Duration(seconds: 10))
        .then<void>(
          (items) =>
              definitions = items.map((item) => item.definition).toList(),
          onError: (Object error) => failure = error,
        );

    // Dio 的拦截器用零时长任务串联，请求到达 gate 后再开始计量回退等待。
    for (var i = 0; i < 20 && adapter.videoRequests.length < 2; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 4));
    final resultBeforeReleasingFallback = definitions;
    final failureBeforeReleasingFallback = failure;
    // 先释放假请求并收尾，确保预期失败不会留下挂起的 Future 或超时计时器。
    gate.complete();
    for (var i = 0; i < 20 && definitions == null && failure == null; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 10));
    await completion;

    _expectIndependentlySignedRequests(adapter, 2);
    expect(failureBeforeReleasingFallback, isNull);
    expect(resultBeforeReleasingFallback, ['1080p']);
  });

  for (final nested in [true, false]) {
    final format = nested ? '数组嵌套格式' : '对象扁平格式';

    test('$format 用旧参数补回兼容档位且保留新 1080P，每次独立签名', () async {
      final (client, adapter) = _client(nested, [
        ('360p', 'bytevc2'),
        ('540p', 'ByteVC2'),
        ('720p', 'bvc2'),
        ('1080p', 'bytevc1'),
      ], legacyStreams: [
        ('720p', 'bytevc1'),
        ('360p', 'bytevc1'),
        ('480p', 'bytevc1'),
        ('540p', 'bytevc1'),
      ]);

      final items = await client.fetchFqVideoModel('7600755504016526398');

      _expectIndependentlySignedRequests(adapter, 2);
      expect(items.map((item) => item.definition),
          unorderedEquals(['360p', '480p', '540p', '720p', '1080p']));
      expect(items.map((item) => item.codec), everyElement('bytevc1'));
      expect(items.singleWhere((item) => item.definition == '1080p').url,
          'https://example.com/current/1080p-bytevc1.mp4');
      expect(items.singleWhere((item) => item.definition == '720p').url,
          'https://example.com/legacy/720p-bytevc1.mp4');
    });

    test('$format 同档位的新兼容视频不会被旧参数覆盖', () async {
      final (client, adapter) = _client(nested, [
        ('720p', 'bytevc1'),
        ('540p', 'bytevc2'),
        ('1080p', 'bytevc1'),
      ], legacyStreams: [
        ('720p', 'bytevc1'),
        ('540p', 'h264'),
        ('1080p', 'bytevc1'),
      ]);

      final items = await client.fetchFqVideoModel('7600755504016526398');

      _expectIndependentlySignedRequests(adapter, 2);
      expect(items.map((item) => item.definition),
          unorderedEquals(['540p', '720p', '1080p']));
      for (final definition in ['720p', '1080p']) {
        expect(items.singleWhere((item) => item.definition == definition).url,
            'https://example.com/current/$definition-bytevc1.mp4');
      }
    });

    test('$format 两次请求都只有不兼容编码时返回明确异常', () async {
      final (client, adapter) = _client(nested, [
        ('360p', 'bytevc2'),
        ('720p', 'bvc2'),
      ], legacyStreams: [
        ('720p', 'ByteVC2'),
      ]);

      await expectLater(
        client.fetchFqVideoModel('7600755504016526398'),
        throwsA(isA<ApiException>()
            .having((error) => error.message, 'message', contains('编码'))),
      );
      _expectIndependentlySignedRequests(adapter, 2);
    });

    test('$format 没有不兼容编码时不额外请求并保留原有顺序', () async {
      final (client, adapter) = _client(nested, [
        ('480p', 'h264'),
        ('1080p', 'bytevc1'),
        ('720p', 'h264'),
      ]);

      final items = await client.fetchFqVideoModel('7600755504016526398');

      _expectIndependentlySignedRequests(adapter, 1);
      expect(items.map((item) => item.definition), ['480p', '1080p', '720p']);
      expect(items.map((item) => item.codec), ['h264', 'bytevc1', 'h264']);
    });

    test('$format 旧参数请求失败时仍保留新请求的兼容 1080P', () async {
      final (client, adapter) = _client(
          nested,
          [
            ('720p', 'bytevc2'),
            ('1080p', 'bytevc1'),
          ],
          legacyFails: true);

      final items = await client.fetchFqVideoModel('7600755504016526398');

      _expectIndependentlySignedRequests(adapter, 2);
      expect(items.map((item) => item.definition), ['1080p']);
      expect(items.single.codec, 'bytevc1');
      expect(items.single.posterUrl, 'https://example.com/poster.jpg');
    });
  }
}
