import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/episode.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/widgets/player/hg_episode_panel.dart';

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

void main() {
  test('按需标题接口保留长ID，空标题正常返回，目录集号不从剧情标题抽数字', () async {
    final api = ApiClient();
    addTearDown(() => api.dio.close(force: true));
    api.dio.httpClientAdapter = _Adapter((options) {
      expect(options.uri.path, '/nove/episodetitles');
      expect(options.uri.queryParameters['book_id'], '7621200213801176126');
      return {
        'code': 0,
        'data': {
          'titles': {'7621200213801176127': '十年之后，故人归来'},
          'available': true
        }
      };
    });
    expect(
        (await api
            .fetchEpisodeTitles('7621200213801176126'))['7621200213801176127'],
        '十年之后，故人归来');
    api.dio.httpClientAdapter = _Adapter((_) => {
          'code': 0,
          'data': {'titles': {}, 'available': false}
        });
    expect(await api.fetchEpisodeTitles('7621200213801176126'), isEmpty);
    api.dio.httpClientAdapter = _Adapter((_) => {
          'code': 0,
          'data': {
            'lists': [
              {
                'item_id': '7621200213801176127',
                'title': '第1集',
                'episode_title': '30年后的重逢'
              },
              {
                'item_id': '7621200213801176128',
                'title': '第2集',
                'episode_title': ''
              },
            ]
          }
        });
    final episodes = await api.fetchTheaterEpisodes('7621200213801176126');
    expect(episodes.chapters.first.title, '30年后的重逢');
    expect(episodes.chapters.first.realChapterOrder, '1');
    expect(episodes.toEpisodes().map((e) => e.index), [1, 2]);
  });

  final episodes = List.generate(
      2,
      (i) => Episode(
          index: i + 1, name: '第${i + 1}集', size: 0, url: '${i + 101}'));
  Future<void> panel(
      WidgetTester tester,
      Future<Map<String, String>> Function() loader,
      ValueChanged<int> selected) async {
    final current = ValueNotifier<int>(0);
    addTearDown(current.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            backgroundColor: kHgPanelBg,
            body: HgEpisodePanel(
                landscape: false,
                dramaName: '测试',
                cover: '',
                intro: '',
                status: '',
                episodes: episodes,
                episodeNotifier: current,
                onSelect: selected,
                loadTitles: loader))));
    await tester.pumpAndSettle();
  }

  testWidgets('切换标题选集才加载，按集ID显示标题并可播放对应集', (tester) async {
    var requests = 0;
    int? selected;
    final result = Completer<Map<String, String>>();
    await panel(tester, () {
      requests++;
      return result.future;
    }, (i) => selected = i);
    expect(requests, 0);
    await tester.tap(find.byTooltip('切换为标题选集'));
    await tester.pump();
    expect(requests, 1);
    expect(find.text('正在加载分集标题…'), findsOneWidget);
    result.complete({'101': '长安初遇', '102': '重逢故人'});
    await tester.pumpAndSettle();
    expect(find.text('长安初遇'), findsOneWidget);
    await tester.tap(find.text('重逢故人'));
    expect(selected, 1);
    await tester.tap(find.byTooltip('切换为数字选集'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换为标题选集'));
    await tester.pumpAndSettle();
    expect(requests, 1);
  });

  testWidgets('无真实标题明确提示，失败可重试且保留序号选集', (tester) async {
    var requests = 0;
    await panel(tester, () async {
      requests++;
      if (requests == 1) throw ApiException('网络异常');
      return {};
    }, (_) {});
    await tester.tap(find.byTooltip('切换为标题选集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分集标题加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('此剧暂未提供分集标题'), findsOneWidget);
    expect(find.text('第1集'), findsOneWidget);
    await tester.tap(find.byTooltip('切换为数字选集'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
  });
}
