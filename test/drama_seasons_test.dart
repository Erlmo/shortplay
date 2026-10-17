import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama_season.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/episode.dart';
import 'package:shortplay/pages/drama_detail_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/detail_episode_strip.dart';
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

List<Episode> _detailEpisodes(WidgetTester tester, bool tv) => tv
    ? tester.widget<EpisodeSelector>(find.byType(EpisodeSelector)).episodes
    : tester
        .widget<DetailEpisodeStrip>(find.byType(DetailEpisodeStrip))
        .episodes;

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
      expect(_detailEpisodes(tester, tv).length, 3);
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
      final episodes = _detailEpisodes(tester, tv);
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
  testWidgets('窄屏封面适度增高，简介默认展开，可收起及切季', (tester) async {
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
        inInclusiveRange(290, 330));
    Text synopsis() =>
        tester.widget<Text>(find.byKey(const ValueKey('synopsis-text')));
    expect(synopsis().maxLines, isNull);
    await tester.ensureVisible(find.text('收起'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(synopsis().maxLines, 2);
    await tester.ensureVisible(find.text('展开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(synopsis().maxLines, isNull);
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
  testWidgets('手机单排选集，全部目录可切换分组，底部播放固定', (tester) async {
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
    expect(find.byType(DetailEpisodeStrip), findsOneWidget);
    expect(find.byType(EpisodeSelector), findsNothing);
    expect(find.text('31-60'), findsNothing);
    final strip = find.byKey(const ValueKey('detail-episode-strip'));
    await tester.drag(strip, const Offset(-800, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多 ›'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-all-episodes')), findsOneWidget);
    await tester.tap(find.text('31-60'));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('detail-all-episodes'));
    expect(
        find.descendant(of: sheet, matching: find.text('31')), findsOneWidget);
    expect(
        find.descendant(of: sheet, matching: find.text('60')), findsOneWidget);
    await tester.tap(find.byTooltip('关闭选集'));
    await tester.pumpAndSettle();
    expect(find.byType(EpisodeSelector), findsNothing);
    expect(tester.getTopLeft(footer).dy, footerTop);
    expect(find.text('立即播放').hitTestable(), findsOneWidget);
    // 顶部“全部”入口也可重复打开，目录回到第一集所在的分组。
    await tester.tap(find.byKey(const ValueKey('detail-show-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-all-episodes')), findsOneWidget);
    expect(
        tester
            .widget<EpisodeSelector>(find.byType(EpisodeSelector))
            .activeIndex,
        0);
    await tester.tap(find.byTooltip('关闭选集'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('单排选集点击对应索引，滑动更多时不误触播放', (tester) async {
    final selected = <int>[];
    var showAll = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
      child: SizedBox(
          width: 340,
          child: DetailEpisodeStrip(
            episodes: List.generate(
                81, (i) => Episode(index: i + 1, name: '', url: '', size: 0)),
            onSelect: selected.add,
            onShowAll: () => showAll++,
          )),
    ))));
    await tester.tap(find.byKey(const ValueKey('episode-2')));
    expect(selected, [2]);
    await tester.drag(find.byKey(const ValueKey('detail-episode-strip')),
        const Offset(-800, 0));
    await tester.pumpAndSettle();
    expect(selected, [2]);
    await tester.tap(find.text('更多 ›'));
    expect(showAll, 1);
  });

  for (final tv in [false, true]) {
    for (final lastIndex in [null, 42]) {
      testWidgets(
          '${tv ? '电视' : '手机'}详情默认第一集，${lastIndex == null ? '首次进入' : '有观看记录'}及切季一致',
          (tester) async {
        DeviceProfile.isTv = tv;
        addTearDown(() => DeviceProfile.isTv = false);
        SharedPreferences.setMockInitialValues({
          if (lastIndex != null)
            'playback_history_v1': jsonEncode([
              for (final id in [_first, _last])
                {
                  'dramaId': int.parse(id),
                  'dramaName': '万妖',
                  'cover': '',
                  'episodeIndex': lastIndex,
                  'positionMs': 60000,
                  'updatedAtMs': 1,
                },
            ]),
        });
        await tester.binding
            .setSurfaceSize(tv ? const Size(960, 540) : const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = _ManyEpisodesCatalog();
        addTearDown(() => api.dio.close(force: true));
        await tester.pumpWidget(MaterialApp(
          home: DramaDetailPage(
            drama: DramaSeason.fromJson((_data['list'] as List)[1]).toDrama(),
            apiClient: api,
          ),
        ));
        await tester.pumpAndSettle();
        void expectFirstEpisode() {
          if (tv) {
            expect(
                tester
                    .widget<EpisodeSelector>(find.byType(EpisodeSelector))
                    .activeIndex,
                0);
          } else {
            expect(find.byType(DetailEpisodeStrip), findsOneWidget);
          }
          expect(find.byKey(const ValueKey('episode-0')), findsOneWidget);
          expect(
              find.byWidgetPredicate((widget) =>
                  widget is Semantics &&
                  widget.properties.label == '第1集' &&
                  widget.properties.selected == true),
              findsOneWidget);
        }

        expectFirstEpisode();
        final season = find.byKey(ValueKey('related-season-$_last'));
        await tester.ensureVisible(season);
        await tester.pumpAndSettle();
        await tester.tap(season);
        await tester.pumpAndSettle();
        expectFirstEpisode();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
