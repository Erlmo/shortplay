import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/danmaku.dart';
import 'package:shortplay/models/episode.dart';
import 'package:shortplay/services/player_danmaku_controller.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/danmaku_service.dart';

class _Call {
  const _Call(this.groupId, this.bookId, this.start, this.cursor, this.cancel);
  final String groupId;
  final String? bookId;
  final int start;
  final String? cursor;
  final CancelToken? cancel;
}

class _Api extends ApiClient {
  _Api(this.respond);
  final FutureOr<DanmakuResponse> Function(_Call) respond;
  final calls = <_Call>[];

  @override
  Future<DanmakuResponse> fetchDanmaku({
    required String groupId,
    String? bookId,
    int? duration,
    int? startOffsetTime,
    String? cursor,
    int count = 90,
    CancelToken? cancelToken,
  }) async {
    final call =
        _Call(groupId, bookId, startOffsetTime ?? 0, cursor, cancelToken);
    calls.add(call);
    return await respond(call);
  }
}

DanmakuComment _comment(String id, int offset) => DanmakuComment(
    id: id, content: id, offsetMs: offset, createTime: 0, userId: '');

DanmakuResponse _batch(int end,
        {bool more = true,
        String cursor = 'cursor',
        List<DanmakuComment> comments = const []}) =>
    DanmakuResponse(
        cursor: cursor,
        hasMore: more,
        total: comments.length,
        comments: comments,
        nextQueryTimeMs: end);

class _Adapter implements HttpClientAdapter {
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    request = options;
    return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'data': {
            'common_list_info': {'has_more': true, 'cursor': '', 'total': 1},
            'extra': {'next_query_danmaku_list_time': 45000},
            'data_list': [
              {
                'comment': {
                  'comment_id': '7621226646028160024',
                  'common': {
                    'content': {'text': '测试弹幕'}
                  },
                  'expand': {
                    'offset_time': 0,
                    'show_boost': 2,
                    'is_force_insert_danmaku': true
                  }
                }
              }
            ]
          }
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Api api;
  late DanmakuService service;

  void setup(FutureOr<DanmakuResponse> Function(_Call) respond) {
    api = _Api(respond);
    service = DanmakuService(apiClient: api);
    addTearDown(service.dispose);
    addTearDown(() => api.dio.close(force: true));
  }

  Future<void> load({String group = 'episode-a', int position = 0}) =>
      service.loadForEpisode(
          groupId: group,
          bookId: '7621200213801176126',
          durationMs: 120000,
          positionMs: position);

  test('真实接口请求携带剧ID及精确时间，解析权重和force字段', () async {
    final client = ApiClient();
    final adapter = _Adapter();
    client.dio.httpClientAdapter = adapter;
    addTearDown(() => client.dio.close(force: true));
    final result = await client.fetchDanmaku(
      groupId: '7621226646028160024',
      bookId: '7621200213801176126',
      duration: 149000,
      startOffsetTime: 17891,
    );
    expect(adapter.request!.uri.queryParameters,
        containsPair('book_id', '7621200213801176126'));
    expect(adapter.request!.uri.queryParameters,
        containsPair('group_id', '7621226646028160024'));
    expect(adapter.request!.uri.queryParameters,
        containsPair('start_offset_time', '17891'));
    expect(result.endOffsetMs, 45000);
    expect(result.hasMore, isTrue);
    expect(result.comments.single.showBoost, 2);
    expect(result.comments.single.forceInsert, isTrue);
  });

  test('控制器清空尚未返回的旧集时也取消请求', () async {
    final old = Completer<DanmakuResponse>();
    final client = _Api((_) => old.future);
    final controller = PlayerDanmakuController(apiClient: client);
    addTearDown(controller.dispose);
    addTearDown(() => client.dio.close(force: true));
    final loading = controller.loadForEpisode(
      episode: Episode(index: 1, name: '第1集', size: 0, url: 'old'),
      bookId: 'series',
      durationMs: 10000,
      isOfflinePlayback: false,
    );
    final token = client.calls.single.cancel!;
    controller.clearComments();
    old.complete(_batch(10000, comments: [_comment('late', 0)]));
    await loading;
    expect(token.isCancelled, isTrue);
    expect(controller.comments, isEmpty);
  });

  test('采用服务端next_query边界，缺失才兼容cursor', () {
    final decoded = DanmakuResponse.fromJson({
      'data': {
        'common_list_info': {
          'cursor': jsonEncode({'end_offset_time': 30000}),
          'has_more': true,
        },
        'extra': {'next_query_danmaku_list_time': '7000'},
      }
    });
    expect(decoded.endOffsetMs, 7000);
    expect(
        DanmakuResponse.fromJson({
          'data': {
            'common_list_info': {
              'cursor': jsonEncode({'end_offset_time': 9000})
            }
          }
        }).endOffsetMs,
        9000);
  });

  test('精确传book_id，0毫秒不再人为均匀分散', () async {
    setup(
        (_) => _batch(7000, comments: [_comment('a', 0), _comment('b', 200)]));
    await load();
    expect(api.calls.single.bookId, '7621200213801176126');
    expect(service.comments.map((c) => c.fireAtMs), [0, 200]);
  });

  test('按非30秒区间提前3秒预取，不依赖cursor非空', () async {
    setup((c) => _batch(c.start == 0 ? 7000 : 15000,
        cursor: '', comments: [_comment('at-${c.start}', c.start)]));
    await load();
    await service.ensureLoadedUpTo(3999);
    expect(api.calls.length, 1);
    await service.ensureLoadedUpTo(4000);
    expect(api.calls.map((c) => c.start), [0, 7000]);
    await service.ensureLoadedUpTo(4500);
    expect(api.calls.length, 2);
  });

  test('空分片继续跟随服务端边界，不因没有弹幕停止', () async {
    setup((c) => _batch(c.start + 8000));
    await load();
    await service.ensureLoadedUpTo(5000);
    expect(api.calls.map((c) => c.start), [0, 8000]);
    expect(service.commentCount, 0);
  });

  test('seek按实际毫秒请求且清cursor，缓存覆盖时不重复获取', () async {
    setup((c) => _batch(c.start + 10000));
    await load();
    await service.ensureLoadedUpTo(43210, seek: true);
    expect(api.calls.last.start, 43210);
    expect(api.calls.last.cursor, isNull);
    await service.ensureLoadedUpTo(1000, seek: true);
    expect(api.calls.length, 2);
  });

  test('正在请求时保留暂停状态下的seek，不等下一个进度事件', () async {
    final first = Completer<DanmakuResponse>();
    setup((c) => c.start == 0 ? first.future : _batch(70000));
    final loading = load();
    final seeking = service.ensureLoadedUpTo(51234, seek: true);
    first.complete(_batch(10000));
    await Future.wait([loading, seeking]);
    expect(api.calls.map((c) => c.start), [0, 51234]);
  });

  test('has_more停止正常续页，但seek可在未缓存位置重新请求', () async {
    setup((c) => _batch(c.start + 10000, more: false));
    await load();
    await service.ensureLoadedUpTo(20000);
    expect(api.calls.length, 1);
    await service.ensureLoadedUpTo(20000, seek: true);
    expect(api.calls.length, 2);
  });

  test('失败总3次尝试且不推进边界，seek成功后恢复预算', () async {
    var fail = true;
    setup((_) {
      if (fail) throw ApiException('network test');
      return _batch(10000);
    });
    await load();
    expect(api.calls.length, 3);
    expect(service.loadedUpToMs, 0);
    expect(service.isLoading, isFalse);
    expect(service.lastError, isA<ApiException>());
    await service.ensureLoadedUpTo(200);
    expect(api.calls.length, 3);
    fail = false;
    await service.ensureLoadedUpTo(500, seek: true);
    expect(api.calls.last.start, 500);
    expect(service.loadedUpToMs, 10000);
    expect(service.lastError, isNull);
    fail = true;
    await service.ensureLoadedUpTo(8000);
    expect(api.calls.length, 7);
    await service.ensureLoadedUpTo(9000);
    expect(api.calls.length, 7);
  });

  test('cursor实际缓存范围优先，seek不重复获取同一服务端窗口', () async {
    setup((_) => _batch(60000,
        cursor: jsonEncode(
            {'start_offset_time': 30000, 'end_offset_time': 60000})));
    await load(position: 43210);
    await service.ensureLoadedUpTo(32000, seek: true);
    expect(api.calls.length, 1);
    expect(service.loadedUpToMs, 60000);
  });

  test('旧位置进度事件不覆盖排队中的精确seek目标', () async {
    final first = Completer<DanmakuResponse>();
    setup((c) => c.start == 0 ? first.future : _batch(70000));
    final loading = load();
    final seeking = service.ensureLoadedUpTo(51234, seek: true);
    unawaited(service.ensureLoadedUpTo(100));
    first.complete(_batch(10000));
    await Future.wait([loading, seeking]);
    expect(api.calls.map((c) => c.start), [0, 51234]);
  });

  test('换集取消旧请求，迟到响应不污染新集', () async {
    final old = Completer<DanmakuResponse>();
    setup((c) => c.groupId == 'episode-a'
        ? old.future
        : _batch(10000, comments: [_comment('new', 1000)]));
    final loadingOld = load();
    final firstToken = api.calls.single.cancel!;
    await load(group: 'episode-b');
    expect(firstToken.isCancelled, isTrue);
    old.complete(_batch(30000, comments: [_comment('old', 2000)]));
    await loadingOld;
    expect(service.comments.map((c) => c.id), ['new']);
    expect(service.loadedUpToMs, 10000);
  });

  test('重叠区间按comment_id去重，避免拖动后重复渲染', () async {
    setup((c) => _batch(c.start + 10000, comments: [
          _comment('same', 8000),
          _comment('at-${c.start}', c.start)
        ]));
    await load();
    await service.ensureLoadedUpTo(7000);
    expect(service.comments.where((c) => c.id == 'same').length, 1);
  });

  test('dispose取消请求并拒绝迟到数据', () async {
    final delayed = Completer<DanmakuResponse>();
    setup((_) => delayed.future);
    final loading = load();
    final token = api.calls.single.cancel!;
    service.dispose();
    delayed.complete(_batch(10000, comments: [_comment('late', 10)]));
    await loading;
    expect(token.isCancelled, isTrue);
    expect(service.comments, isEmpty);
  });
}
