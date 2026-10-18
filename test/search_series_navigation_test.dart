import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/search_results.dart';
import 'package:shortplay/models/search_series_card.dart';
import 'package:shortplay/models/search_source.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/pages/search_results_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/search_series_card.dart';
import 'package:shortplay/widgets/tv_tap.dart';

Map<String, dynamic> _video(String id, String title) => {
      'series_id': id,
      'title': title,
      'video_detail': {'series_id': id},
    };

Map<String, dynamic> _doc(String id, String title) => {
      'show_type': 659,
      'search_ip_card_content_type': 2,
      'video_data': [_video(id, title)],
    };

Map<String, dynamic> _series() => {
      'show_type': 655,
      'cell_name': '万妖图录传',
      'search_ip_card_selected_idx': 0,
      'cell_data': [
        {
          'show_type': 658,
          'cell_name': '爆款系列',
          'search_ip_card_selected_idx': 2,
          'cell_data': [
            _doc('7621200213801176126', '第一季'),
            _doc('7628202881140657177', '第二季'),
            _doc('7690163276214176792', '第十三季'),
          ],
        },
        {
          'show_type': 658,
          'cell_name': '其他版本',
          'cell_data': [_doc('123456', '其他版本作品')],
        },
      ],
    };

class _Client extends ApiClient {
  _Client({this.v3 = false});

  final bool v3;
  final requests = <SearchQuery>[];
  final opened = <String>[];
  final seasonRequests = <(String, SearchSource)>[];

  @override
  Future<SearchResultsResponse> searchResults(SearchQuery query,
      {CancelToken? cancelToken}) async {
    requests.add(query);
    return SearchResultsResponse.fromJson({
      'selected_tab_idx': 0,
      'search_tabs': [
        for (final tab in [(19, '综合'), (32, '漫剧'), (11, '短剧')])
          {
            'tab_type': tab.$1,
            'title': tab.$2,
            'data': [
              if (v3)
                {
                  'show_type': 657,
                  'cell_name': '万妖图录传',
                  'cell_data': [
                    for (final season in [
                      ('7621200213801176126', '第一季'),
                      ('7690163276214176792', '第十三季'),
                    ])
                      {
                        'show_type': 658,
                        'cell_id_str': season.$1,
                        'cell_name': season.$2,
                        'video_data': [
                          {
                            ..._video(season.$1, season.$2),
                            'cover': 'https://example.invalid/cover',
                          },
                        ],
                      },
                  ],
                }
              else
                _series(),
            ],
          },
      ],
    }, source: query.source);
  }

  @override
  Future<List<SearchSeriesEpisode>> fetchSearchSeason(String seriesId,
      {SearchSource source = SearchSource.comic,
      CancelToken? cancelToken}) async {
    seasonRequests.add((seriesId, source));
    return [
      for (final number in [1, 7])
        SearchSeriesEpisode(
          vid: '$seriesId-$number',
          seriesId: seriesId,
          number: number,
          title: '$number',
          raw: const {},
        ),
    ];
  }

  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) {
    opened.add(seriesId);
    return Completer<TheaterEpisodesResult>().future;
  }
}

void main() {
  tearDown(() => DeviceProfile.isTv = false);

  testWidgets('正式结果655第十三季进入真实作品，返回保留搜索会话', (tester) async {
    final api = _Client();
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(MaterialApp(
      home: SearchResultsPage(keyword: '万妖图录传第十三季', apiClient: api),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-series-item-0-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(tester.widget<PlayerPage>(find.byType(PlayerPage)).drama.id,
        7690163276214176792);
    Navigator.of(tester.element(find.byType(PlayerPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SearchSeriesCard), findsOneWidget);
    expect(api.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('普通369结果即使剧名相同也不自动归并系列', () {
    final tab = SearchResultTab.fromJson({
      'tab_type': 32,
      'title': '漫剧',
      'data': [
        for (final id in ['7621200213801176126', '7690163276214176792'])
          {
            'show_type': 369,
            'video_data': [_video(id, '万妖图录传')],
          },
      ],
    });
    expect(tab.groups, hasLength(2));
    expect(tab.groups.expand((group) => group.seriesCards), isEmpty);
    expect(tab.groups.expand((group) => group.entries).map((drama) => drama.id),
        [7621200213801176126, 7690163276214176792]);
  });

  testWidgets('TV切换655模块后从顶部分类向下仍能进入当前横排', (tester) async {
    DeviceProfile.isTv = true;
    final api = _Client();
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(MaterialApp(
      home: SearchResultsPage(keyword: '万妖', apiClient: api),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-series-group-1')));
    await tester.pumpAndSettle();
    final currentItem = tester
        .widget<TvTap>(find.byKey(const ValueKey('search-series-item-1-0')));
    final scope = tester.widget<TvTap>(
        find.byKey(const ValueKey('search-scope-hongguo_comic:19:')));
    scope.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(currentItem.focusNode!.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('正式结果657按当前来源加载选中季，点第七集保留原始集数', (tester) async {
    final api = _Client(v3: true);
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(MaterialApp(
      home: SearchResultsPage(keyword: '万妖', apiClient: api),
    ));
    await tester.pumpAndSettle();
    expect(api.seasonRequests, [('7621200213801176126', SearchSource.comic)]);
    final season = find.byKey(const ValueKey('search-series-v3-season-1'));
    await tester.ensureVisible(season);
    await tester.tap(season);
    await tester.pumpAndSettle();
    expect(
        api.seasonRequests.last, ('7690163276214176792', SearchSource.comic));
    expect(find.byType(PlayerPage), findsNothing);
    final episode = find.byKey(const ValueKey('search-series-v3-episode-1'));
    await tester.ensureVisible(episode);
    await tester.tap(episode);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.drama.id, 7690163276214176792);
    expect(player.initialEpisodeNumber, 7);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
