import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/main.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/services/download_service.dart';

import 'support/no_app_updates.dart';

class _RankAdapter implements HttpClientAdapter {
  _RankAdapter({this.unavailable = true});

  final bool unavailable;
  final ranks = <String>[];
  final requests = <Map<String, String>>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final rank = options.uri.queryParameters['rank']!;
    ranks.add(rank);
    requests.add(options.uri.queryParameters);
    if (!unavailable) {
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'data': {
            'rank': 'hotsearch',
            'offset':
                int.tryParse(options.uri.queryParameters['offset'] ?? '0'),
            'session_id': 'hot-search-session',
            'has_more': true,
            'next_offset': 10,
            'list': [
              {'series_id': '7621200213801176126', 'title': '热搜短剧'}
            ],
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        },
      );
    }
    return ResponseBody.fromString(
        jsonEncode({'code': 503, 'message': '热搜榜加载失败，请稍后重试'}), 503,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

class _HomeApi extends ApiClient {
  final ranks = <String>[];
  bool unavailable = true;
  @override
  Future<List<String>> fetchNotice() async => [];
  @override
  Future<HomePageResult> fetchHomePage(
          {int? offset, String? sessionId}) async =>
      HomePageResult(
          offset: 0,
          sessionId: '',
          count: 0,
          hasMore: false,
          nextOffset: 0,
          list: []);
  @override
  Future<NewPlayResult> fetchNewPlay(
          {int? offset, String? sessionId, String? cellGender}) async =>
      NewPlayResult(
          offset: 0,
          sessionId: '',
          count: 0,
          hasMore: false,
          nextOffset: 0,
          list: []);
  @override
  Future<RankListResult> fetchRankList(
      {required String rankType,
      String type = 'all',
      String? cellGender,
      int? offset,
      String? sessionId}) async {
    ranks.add(rankType);
    if (rankType == 'hotsearch' && unavailable) {
      throw ApiException('热搜榜加载失败，请稍后重试');
    }
    return RankListResult(
        offset: 0,
        sessionId: '',
        count: 0,
        hasMore: false,
        nextOffset: 0,
        list: []);
  }
}

void main() {
  test('热搜列表解析并沿用上游会话和偏移量翻页', () async {
    final api = ApiClient();
    final adapter = _RankAdapter(unavailable: false);
    api.dio.httpClientAdapter = adapter;
    addTearDown(() => api.dio.close(force: true));
    final first =
        await api.fetchRankList(rankType: 'hotsearch', type: 'female');
    expect(first.list.single.name, '热搜短剧');
    expect(first.list.single.id, 7621200213801176126);
    expect(first.hasMore, isTrue);
    await api.fetchRankList(
      rankType: 'hotsearch',
      type: 'female',
      offset: first.nextOffset,
      sessionId: first.sessionId,
    );
    expect(adapter.ranks, ['hotsearch', 'hotsearch']);
    expect(adapter.requests.last, containsPair('offset', '10'));
    expect(adapter.requests.last,
        containsPair('session_id', 'hot-search-session'));
    expect(adapter.requests.last, containsPair('type', 'female'));
  });

  test('热搜独立传参并保留上游不可用提示', () async {
    final api = ApiClient();
    final adapter = _RankAdapter();
    api.dio.httpClientAdapter = adapter;
    addTearDown(() => api.dio.close(force: true));
    await expectLater(
        api.fetchRankList(rankType: 'hotsearch'),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', '热搜榜加载失败，请稍后重试')));
    expect(adapter.ranks, ['hotsearch']);
  });

  for (final tv in [true, false]) {
    testWidgets('${tv ? '电视' : '手机'}保留收藏并展示热搜入口，加载失败可重试', (tester) async {
      SharedPreferences.setMockInitialValues({});
      DeviceProfile.isTv = tv;
      addTearDown(() => DeviceProfile.isTv = false);
      await tester.binding
          .setSurfaceSize(tv ? const Size(960, 540) : const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _HomeApi();
      final downloads = DownloadService(apiClient: api);
      addTearDown(downloads.dispose);
      addTearDown(() => api.dio.close(force: true));
      await tester.pumpWidget(ShortPlayApp(
          apiClient: api,
          downloadService: downloads,
          appUpdateService: NoAppUpdates(api)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('飙升'), findsNothing);
      await tester.ensureVisible(find.text('热搜'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      if (tv) {
        Focus.of(tester.element(find.text('热搜'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(find.text('热搜'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(api.ranks, contains('hotsearch'));
      expect(find.text('热搜榜加载失败，请稍后重试'), findsOneWidget);
      final before = api.ranks.where((r) => r == 'hotsearch').length;
      api.unavailable = false;
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(api.ranks.where((r) => r == 'hotsearch').length, before + 1);
      expect(find.text('热搜榜加载失败，请稍后重试'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
