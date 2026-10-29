import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/twixive.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/hidden_feed_access.dart';

class TwixiveAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Map<String, dynamic> response = {'items': []};
  int status = 200;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
        jsonEncode(status == 200
            ? {'code': 0, 'data': response}
            : {'code': status, 'message': '来源暂不可用'}),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('首页模式可保存恢复，首次安装默认关闭', () async {
    final access = HiddenFeedAccess();
    await access.load();
    expect(access.enabled, isFalse);
    await access.toggle();
    expect(access.enabled, isTrue);
    final restored = HiddenFeedAccess();
    await restored.load();
    expect(restored.enabled, isTrue);
    await restored.toggle();
    expect(restored.enabled, isFalse);
  });

  test('口令验证使用服务端 POST 结果，不在客户端比较口令', () async {
    final adapter = TwixiveAdapter()..response = {'valid': false};
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    expect(await api.verifyTwixiveAccess('test-pass'), isFalse);
    adapter.response = {'valid': true};
    expect(await api.verifyTwixiveAccess('test-pass'), isTrue);
    expect(adapter.requests.last.path, '/twixive/access');
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.data, {'phrase': 'test-pass'});
    expect(adapter.requests.last.queryParameters, isEmpty);
    expect(
        (await SharedPreferences.getInstance())
            .getBool(HiddenFeedAccess.preferenceKey),
        isNull);
  });

  test('所有新栏目映射到服务端接口，用户分页原样传递游标', () async {
    final adapter = TwixiveAdapter();
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    for (final feed in TwixiveFeed.values) {
      await api.fetchTwixivePage(feed: feed, days: 7, offset: 24);
    }
    expect(adapter.requests.map((r) => r.path), [
      '/twixive',
      '/twixive/new',
      '/twixive/ranking',
      '/twixive/trendvideos',
      '/twixive/trendusers'
    ]);
    expect(adapter.requests[2].queryParameters['days'], 7);
    expect(adapter.requests.every((r) => r.queryParameters['offset'] == 24),
        isTrue);
    adapter.response = {
      'user': {'username': 'example'},
      'videos': [],
      'pageInfo': {'nextCursor': 'opaque+/=value'}
    };
    final result =
        await api.fetchTwixivePage(user: 'example', cursor: 'opaque+/=value');
    expect(adapter.requests.last.path, '/twixive/uservideos');
    expect(adapter.requests.last.queryParameters['cursor'], 'opaque+/=value');
    expect(
        adapter.requests.last.queryParameters.containsKey('offset'), isFalse);
    expect(result.nextCursor, 'opaque+/=value');
    expect(result.hasMore, isTrue);
  });

  test('服务端错误保留可读信息，不回退到短剧解析', () async {
    final adapter = TwixiveAdapter()..status = 503;
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(api.dispose);
    await expectLater(
        api.fetchTwixivePage(),
        throwsA(
            isA<ApiException>().having((e) => e.message, 'message', '来源暂不可用')));
    expect(adapter.requests, hasLength(1));
  });

  test('列表解析保留直链，过滤无效地址，并处理用户视频作者与分页终点', () {
    final result = TwixivePage.fromJson({
      'items': [
        {
          'video': {
            'id': '123',
            'url': 'https://video.example/123.mp4?tag=1',
            'author': {'username': 'example'}
          }
        },
        {
          'video': {'id': '456', 'url': 'javascript:bad'}
        },
      ]
    }, offset: 24, limit: 24);
    expect(result.videos.single.url, 'https://video.example/123.mp4?tag=1');
    expect(result.nextOffset, 26);
    expect(result.hasMore, isFalse);
    final userPage = TwixivePage.fromJson({
      'user': {'id': '10', 'username': 'author', 'name': '作者'},
      'videos': [
        {'id': '123', 'url': 'https://video.example/123.mp4'}
      ],
      'pageInfo': {'hasNextPage': false, 'nextCursor': null},
    }, offset: 0, limit: 24, userVideos: true);
    expect(userPage.videos.single.author.label, '作者');
    expect(userPage.hasMore, isFalse);
  });
}
