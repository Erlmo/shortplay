import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/api_client.dart';

import 'support/video_resolution_adapter.dart';

void main() {
  test('解析后读取key命中服务端返回值，不再请求解密接口', () async {
    final adapter = VideoResolutionAdapter();
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    final stream = (await api.fetchFqVideoModel('1234567890')).single;
    expect(await api.fetchDecryptKey(stream.spadeA), stream.decryptKey);
    expect(adapter.requests, hasLength(1));
  });
  test('同集并发解析合并，不同集各自发送视频ID', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    var enteredCount = 0;
    final adapter = VideoResolutionAdapter(reply: (_) async {
      if (++enteredCount == 2) entered.complete();
      await gate.future;
      return resolutionJson(resolutionResponse());
    });
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    final a = api.fetchFqVideoModel('1234567890');
    final b = api.fetchFqVideoModel('1234567890');
    final c = api.fetchFqVideoModel('2234567890');
    await entered.future.timeout(const Duration(seconds: 5));
    expect(adapter.requests, hasLength(2));
    gate.complete();
    expect(await a, same(await b));
    expect(await c, isNotEmpty);
  });
  test('请求失败不保留进行中缓存，下一次可重试', () async {
    var fail = true;
    final adapter = VideoResolutionAdapter(
        reply: (_) => fail
            ? resolutionJson({'code': 503, 'message': '暂时失败'}, status: 503)
            : resolutionJson(resolutionResponse()));
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    await expectLater(
        api.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
    fail = false;
    expect(await api.fetchFqVideoModel('1234567890'), isNotEmpty);
    expect(adapter.requests, hasLength(2));
  });
  test('过期的播放结果和key不继续复用，也不发送旧spade补救', () async {
    var now = DateTime.utc(2026, 10, 28);
    final expire =
        now.add(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000;
    final adapter = VideoResolutionAdapter(
        reply: (_) => resolutionJson(resolutionResponse(streams: [
              resolvedVideoStream()..['expire_time'] = expire,
            ])));
    final api =
        ApiClient(dio: Dio()..httpClientAdapter = adapter, clock: () => now);
    addTearDown(api.dispose);
    final item = (await api.fetchFqVideoModel('1234567890')).single;
    now = now.add(const Duration(minutes: 2));
    await expectLater(
        api.fetchDecryptKey(item.spadeA), throwsA(isA<ApiException>()));
    await expectLater(
        api.fetchFqVideoModel('1234567890'), throwsA(isA<ApiException>()));
    expect(adapter.requests.map((r) => r.uri.path),
        everyElement('/algorithm/videorequest'));
  });
}
