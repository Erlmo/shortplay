import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/api_client.dart';

// 使用实测搜索响应的字段结构，图片改为不访问网络的示例地址。
const _video = <String, Object>{
  'title': '一零重生之热血商途',
  'cover': 'https://example.com/cover.jpg',
  'series_id': '7669407239530089496',
  'rec_text': '2355万热度',
  'score': '8.1',
  'episode_cnt': 86,
  'play_cnt': 130272,
  'category_schema': '[{"name":"都市"},{"name":"重生逆袭"},{"name":"商战风云"}]',
  'video_detail': {
    'series_id': '7669407239530089496',
    'series_title': '一零重生之热血商途',
    'series_cover': 'https://example.com/cover.jpg',
    'series_intro': '吴世道重生回到2010年，凭借未来记忆改写命运。',
    'series_status': 1,
    'episode_cnt': 86,
    'role': '吴世道,沈晓静,胡斌,刘双双',
  },
};

Map<String, Object> _otherVideo(String id) => {
      ..._video,
      'series_id': id,
      'video_detail': {
        ...(_video['video_detail']! as Map<String, Object>),
        'series_id': id,
      },
    };

Map<String, Object> _page(List<Map<String, Object>> videos,
        {bool hasMore = false}) =>
    {
      'code': 0,
      'message': 'success',
      'search_tabs': [
        {
          'tab_type': 11,
          'has_more': hasMore,
          'data': [
            for (final video in videos)
              {
                'video_data': [video],
              },
          ],
        },
      ],
    };

class _SearchAdapter implements HttpClientAdapter {
  _SearchAdapter(this.pages);

  final Map<int, Map<String, Object>> pages;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options.uri);
    if (options.uri.path != '/nove/search') {
      throw StateError('不应请求旧详情接口: ${options.uri.path}');
    }
    final offset = int.parse(options.uri.queryParameters['offset'] ?? '0');
    final response = pages[offset];
    if (response == null) throw StateError('不应请求 offset=$offset');
    return ResponseBody.fromString(jsonEncode(response), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

(ApiClient, _SearchAdapter) _client(Map<int, Map<String, Object>> pages) {
  final adapter = _SearchAdapter(pages);
  final dio = Dio()..httpClientAdapter = adapter;
  return (ApiClient(dio: dio), adapter);
}

Matcher get _detailsNotFound => isA<ApiException>().having(
      (error) => error.message,
      'message',
      '已识别到短剧，但暂未找到详情，请稍后重试',
    );

void main() {
  test('分享详情保留搜索返回的封面简介标签评分及集数', () async {
    final (client, adapter) = _client({
      0: _page([_video])
    });

    final drama = await client.fetchSharedDramaDetail(
      '7669407239530089496',
      title: '  一零重生之热血商途  ',
    );

    expect(drama.id, 7669407239530089496);
    expect(drama.name, '一零重生之热血商途');
    expect(drama.cover, 'https://example.com/cover.jpg');
    expect(drama.intro, '吴世道重生回到2010年，凭借未来记忆改写命运。');
    expect(drama.tags, ['都市', '重生逆袭', '商战风云']);
    expect(drama.score, '8.1');
    expect(drama.recText, '2355万热度');
    expect(drama.playCnt, 130272);
    expect(drama.role, '吴世道,沈晓静,胡斌,刘双双');
    expect(drama.updateTime, '全86集');
    expect(drama.status, '已完结');
    expect(drama.isTheaterResource, isTrue);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.queryParameters, {
      'key': '一零重生之热血商途',
      'tab_type': '11',
    });
  });

  test('分享详情跳过同名但作品ID不同的首个结果', () async {
    final (client, _) = _client({
      0: _page([_otherVideo('7669407239530089000'), _video]),
    });

    final drama = await client.fetchSharedDramaDetail(
      '7669407239530089496',
      title: '一零重生之热血商途',
    );

    expect(drama.id, 7669407239530089496);
    expect(drama.cover, 'https://example.com/cover.jpg');
  });

  test('分享详情继续下一页查找并使用已返回作品数作为offset', () async {
    final (client, adapter) = _client({
      0: _page([
        _otherVideo('7669407239530089000'),
        _otherVideo('7669407239530089001'),
      ], hasMore: true),
      2: _page([_video]),
    });

    final drama = await client.fetchSharedDramaDetail(
      '7669407239530089496',
      title: '一零重生之热血商途',
    );

    expect(drama.id, 7669407239530089496);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.queryParameters['offset'], '2');
  });

  test('只有同名的其他作品时返回明确错误并停止翻页', () async {
    final (client, adapter) = _client({
      0: _page([_otherVideo('7669407239530089000')]),
    });

    await expectLater(
      client.fetchSharedDramaDetail('7669407239530089496', title: '一零重生之热血商途'),
      throwsA(_detailsNotFound),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('搜索返回空页时即使hasMore为true也停止查找', () async {
    final (client, adapter) = _client({0: _page([], hasMore: true)});

    await expectLater(
      client.fetchSharedDramaDetail('7669407239530089496', title: '一零重生之热血商途'),
      throwsA(_detailsNotFound),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('分享详情最多查找三页不无限获取推荐结果', () async {
    final (client, adapter) = _client({
      0: _page([_otherVideo('1')], hasMore: true),
      1: _page([_otherVideo('2')], hasMore: true),
      2: _page([_otherVideo('3')], hasMore: true),
      3: _page([_video]),
    });

    await expectLater(
      client.fetchSharedDramaDetail('7669407239530089496', title: '一零重生之热血商途'),
      throwsA(_detailsNotFound),
    );
    expect(adapter.requests, hasLength(3));
  });

  test('空剧名不发请求并提示复制完整分享内容', () async {
    final (client, adapter) = _client({});

    await expectLater(
      client.fetchSharedDramaDetail('7669407239530089496', title: ' \n '),
      throwsA(isA<ApiException>().having(
        (error) => error.message,
        'message',
        contains('包含剧名的完整分享内容'),
      )),
    );
    expect(adapter.requests, isEmpty);
  });

  for (final id in ['', '0', '-1', 'abc', '0x123']) {
    test('无效作品ID「$id」不发请求', () async {
      final (client, adapter) = _client({});

      await expectLater(
        client.fetchSharedDramaDetail(id, title: '一零重生之热血商途'),
        throwsA(isA<ApiException>()),
      );
      expect(adapter.requests, isEmpty);
    });
  }
}
