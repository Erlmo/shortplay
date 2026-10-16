import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama_season.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/drama_detail_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/related_seasons.dart';
import 'package:shortplay/widgets/episode_selector.dart';

const _first = '7621200213801176126';
const _last = '7690163276214176792';
final _data = <String, dynamic>{
  'album_id': '7624475539960499262',
  'current_season': 1,
  'list': [
    {
      'series_id': _last,
      'title': '万妖第十三季',
      'season_order': 13,
      'episode_cnt': 209
    },
    {
      'series_id': _first,
      'title': '万妖第一季',
      'season_order': 1,
      'episode_cnt': 81
    },
    {'series_id': _first, 'season_order': 1},
    {'series_id': 'invalid'},
  ],
};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Map<String, dynamic> Function(RequestOptions) reply;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromString(jsonEncode(reply(options)), 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      });
  @override
  void close({bool force = false}) {}
}

class _Catalog extends ApiClient {
  final seasonRequests = <String>[];
  final episodeRequests = <String>[];
  bool failOnce = false;
  bool single = false;
  @override
  Future<DramaSeasons> fetchDramaSeasons(String seriesId,
      {CancelToken? cancelToken}) async {
    seasonRequests.add(seriesId);
    if (failOnce) {
      failOnce = false;
      throw ApiException('临时失败');
    }
    return DramaSeasons.fromJson(single ? {'list': []} : _data);
  }

  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) async {
    episodeRequests.add(seriesId);
    return TheaterEpisodesResult(
        allItemIds: [],
        chapters: List.generate(
            seriesId == _first ? 3 : 5,
            (i) => TheaterChapter(
                itemId: '',
                title: '$seriesId 第${i + 1}集',
                realChapterOrder: '${i + 1}')));
  }
}

class _DelayedCatalog extends _Catalog {
  final delayed = Completer<TheaterEpisodesResult>();
  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) {
    if (seriesId == _last) {
      episodeRequests.add(seriesId);
      return delayed.future;
    }
    return super.fetchTheaterEpisodes(seriesId);
  }
}

class _ManyEpisodesCatalog extends _Catalog {
  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) async =>
      TheaterEpisodesResult(
          allItemIds: [],
          chapters: List.generate(
              81,
              (i) => TheaterChapter(
                  itemId: '',
                  title: '第${i + 1}集',
                  realChapterOrder: '${i + 1}')));
}

void main() {
  test('其他季保留大整数ID、去重排序并保持可播放资源类型', () {
    final result = DramaSeasons.fromJson(_data);
    expect(result.seasons.map((s) => s.id.toString()), [_first, _last]);
    expect(result.seasons.last.toDrama().isTheaterResource, isTrue);
    expect(result.seasons.last.toDrama().subTitle, '共209集');
  });

  test('其他季请求路径和参数正确，显示服务端业务错误', () async {
    final client = ApiClient();
    addTearDown(() => client.dio.close(force: true));
    client.dio.httpClientAdapter = _Adapter((request) {
      expect(request.uri.path, '/nove/seasons');
      expect(request.queryParameters['book_id'], _first);
      return {'code': 0, 'data': _data};
    });
    expect((await client.fetchDramaSeasons(_first)).seasons.length, 2);
    client.dio.httpClientAdapter =
        _Adapter((_) => {'code': 502, 'message': '获取其他季失败'});
    await expectLater(
        client.fetchDramaSeasons(_first),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', '获取其他季失败')));
  });

  for (final tv in [true, false]) {
    testWidgets('${tv ? '电视' : '手机'}详情显示其他季并切换到对应目录', (tester) async {
      DeviceProfile.isTv = tv;
      SharedPreferences.setMockInitialValues({});
      addTearDown(() {
        DeviceProfile.isTv = false;
      });
      await tester.binding
          .setSurfaceSize(tv ? const Size(960, 540) : const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Catalog();
      addTearDown(() => api.dio.close(force: true));
      await tester.pumpWidget(MaterialApp(
          home: DramaDetailPage(
        drama: DramaSeason.fromJson((_data['list'] as List)[1]).toDrama(),
        apiClient: api,
      )));
      await tester.pumpAndSettle();
      final card = find.byKey(ValueKey('related-season-$_last'));
      if (tv) {
        await tester.ensureVisible(card);
      } else {
        await tester.scrollUntilVisible(card, 250,
            scrollable: find.byType(Scrollable).first);
      }
      await tester.pumpAndSettle();
      expect(find.text('其他季'), findsNothing);
      expect(
          find.ancestor(
              of: card,
              matching: find.byKey(const ValueKey('season-episode-selector'))),
          findsOneWidget);
      final originalState = tester.state(find.byType(DramaDetailPage));
      expect(
          tester
              .widget<EpisodeSelector>(find.byType(EpisodeSelector))
              .episodes
              .length,
          3);
      if (tv) {
        final detector = find.descendant(
            of: card, matching: find.byType(FocusableActionDetector));
        Focus.of(tester.element(find
                .descendant(of: detector, matching: find.byType(AnimatedScale))
                .first))
            .requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(card);
      }
      await tester.pumpAndSettle();
      expect(api.seasonRequests, [_first]);
      expect(api.episodeRequests, [_first, _last]);
      expect(tester.state(find.byType(DramaDetailPage)), same(originalState));
      expect(
          tester
              .widget<RelatedSeasons>(find.byType(RelatedSeasons))
              .currentId
              .toString(),
          _last);
      final episodes =
          tester.widget<EpisodeSelector>(find.byType(EpisodeSelector)).episodes;
      expect(episodes.length, 5);
      expect(episodes.first.name, startsWith(_last));
      // 再次点击当前季不重复请求或重置当前选集。
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(api.episodeRequests, [_first, _last]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('单季不显示关联，失败可重试', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _Catalog()..failOnce = true;
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(MaterialApp(
        home: DramaDetailPage(
      drama: DramaSeason.fromJson((_data['list'] as List)[1]).toDrama(),
      apiClient: api,
    )));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('其他季暂时加载失败'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('其他季暂时加载失败'), findsOneWidget);
    api.single = true;
    await tester.ensureVisible(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(api.seasonRequests.length, 2);
    expect(find.byType(RelatedSeasons), findsNothing);
    expect(find.text('其他季暂时加载失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('快速切季时，旧目录迟到不会覆盖当前季', (tester) async {
    SharedPreferences.setMockInitialValues({});
    DeviceProfile.isTv = true;
    addTearDown(() => DeviceProfile.isTv = false);
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _DelayedCatalog();
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(MaterialApp(
        home: DramaDetailPage(
      drama: DramaSeason.fromJson((_data['list'] as List)[1]).toDrama(),
      apiClient: api,
    )));
    await tester.pumpAndSettle();
    final last = find.byKey(ValueKey('related-season-$_last'));
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pump();
    final first = find.byKey(ValueKey('related-season-$_first'));
    await tester.ensureVisible(first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(first);
    await tester.pumpAndSettle();
    api.delayed.complete(TheaterEpisodesResult(
        allItemIds: [],
        chapters: [],
        bookInfo: DramaSeason.fromJson((_data['list'] as List)[0]).toDrama()));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<RelatedSeasons>(find.byType(RelatedSeasons))
            .currentId
            .toString(),
        _first);
    expect(
        tester
            .widget<EpisodeSelector>(find.byType(EpisodeSelector))
            .episodes
            .length,
        3);
    expect(api.episodeRequests, [_first, _last, _first]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('窄屏详情封面紧凑，简介折叠，选集和季切换仍完整可用', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _Catalog();
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(MaterialApp(
        home: DramaDetailPage(
      drama: Drama(
          id: int.parse(_first),
          name: '万妖图录传第一季',
          actors: '',
          cover: '',
          intro: '少女误入妖族世界，与伙伴一起寻找身世的秘密。' * 15,
          tags: [],
          status: '已完结',
          updateTime: '',
          score: '8.2',
          pureCategoryTags: '剧情,古风',
          isTheaterResource: true),
      apiClient: api,
    )));
    await tester.pumpAndSettle();
    expect(
        tester.widget<SliverAppBar>(find.byType(SliverAppBar)).expandedHeight,
        lessThanOrEqualTo(210));
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('synopsis-text')))
            .maxLines,
        2);
    await tester.ensureVisible(find.text('展开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('synopsis-text')))
            .maxLines,
        isNull);
    await tester.ensureVisible(find.text('收起'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    final season = find.byKey(ValueKey('related-season-$_last'));
    await tester.scrollUntilVisible(season, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(season);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<RelatedSeasons>(find.byType(RelatedSeasons))
            .currentId
            .toString(),
        _last);
    expect(tester.takeException(), isNull);
  });
  testWidgets('A方案底部播放固定，当前分组完整展示并可切换集数范围', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ManyEpisodesCatalog();
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(MaterialApp(
        home: DramaDetailPage(
      drama: DramaSeason.fromJson((_data['list'] as List)[1]).toDrama(),
      apiClient: api,
    )));
    await tester.pumpAndSettle();
    final footer = find.byKey(const ValueKey('detail-play-bar'));
    final footerTop = tester.getTopLeft(footer).dy;
    expect(find.text('立即播放').hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(find.text('31-60'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final selector =
        tester.widget<EpisodeSelector>(find.byType(EpisodeSelector));
    expect(selector.embedded, isTrue);
    expect(find.text('30'), findsOneWidget);
    await tester.tap(find.text('31-60'));
    await tester.pumpAndSettle();
    expect(find.text('31'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(tester.getTopLeft(footer).dy, footerTop);
    expect(find.text('立即播放').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
