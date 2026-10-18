import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/search_series_card.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/search_series_card.dart';
import 'package:shortplay/widgets/tv_tap.dart';

// 真实 74032 第十三季响应的655首卡，移除签名图片及无关报告字段。
Map<String, dynamic> fixture() => jsonDecode(
        r'''{"show_type":655,"cell_name":"万妖图录传","search_ip_card_selected_idx":0,"cell_data":[{"show_type":658,"cell_name":"爆款系列","search_ip_card_selected_idx":12,"cell_data":[{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第1季","rich_text":"第1季","high_light_position":[]}},"video_data":[{"series_id":"7621200213801176126","title":"万妖图录传第一季","episode_cnt":81}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第2季","rich_text":"第2季","high_light_position":[]}},"video_data":[{"series_id":"7628202881140657177","title":"万妖图录传第二季","episode_cnt":53}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第3季","rich_text":"第3季","high_light_position":[]}},"video_data":[{"series_id":"7633436713011907608","title":"万妖图录传第三季","episode_cnt":58}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第4季","rich_text":"第4季","high_light_position":[]}},"video_data":[{"series_id":"7637517119122312254","title":"万妖图录传第四季","episode_cnt":69}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第5季","rich_text":"第5季","high_light_position":[]}},"video_data":[{"series_id":"7642602521285889048","title":"万妖图录传第五季","episode_cnt":64}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第6季","rich_text":"第6季","high_light_position":[]}},"video_data":[{"series_id":"7645616042022014014","title":"万妖图录传第六季","episode_cnt":90}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第7季","rich_text":"第7季","high_light_position":[]}},"video_data":[{"series_id":"7651944586545220633","title":"万妖图录传第七季","episode_cnt":90}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第8季","rich_text":"第8季","high_light_position":[]}},"video_data":[{"series_id":"7660437812851788862","title":"万妖图录传第八季","episode_cnt":109}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第9季","rich_text":"第9季","high_light_position":[]}},"video_data":[{"series_id":"7663319902001843225","title":"万妖图录传第九季","episode_cnt":107}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第10季","rich_text":"第10季","high_light_position":[]}},"video_data":[{"series_id":"7669384046295649342","title":"万妖图录传第十季","episode_cnt":116}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第11季","rich_text":"第11季","high_light_position":[]}},"video_data":[{"series_id":"7673810791547538494","title":"万妖图录传第十一季","episode_cnt":164}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第12季","rich_text":"第12季","high_light_position":[]}},"video_data":[{"series_id":"7681495327056071704","title":"万妖图录传第十二季","episode_cnt":200}]},{"show_type":659,"search_ip_card_content_type":2,"search_high_light":{"title":{"text":"第13季","rich_text":"<em>第13季</em>","high_light_position":[[0,4]]}},"video_data":[{"series_id":"7690163276214176792","title":"万妖图录传第十三季","episode_cnt":209}]},{"show_type":659,"search_ip_card_content_type":21,"search_high_light":{"title":{"text":"第14季","rich_text":"第14季","high_light_position":[]}},"subscribe_items":[{"item_id":7691518344146455576,"name":"万妖图录传第十四季"}]}]},{"show_type":658,"cell_name":"其他版本","cell_data":[{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7656652779691183128","title":"万妖图录传：那妖魔是姜大人","episode_cnt":102}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7617687367452724249","title":"万妖图录传","episode_cnt":60}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7633275976180304958","title":"万妖图录传：月落镇魔第二季","episode_cnt":60}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7636655886479395865","title":"万妖图录传：月落镇魔第三季","episode_cnt":45}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7638528326281202713","title":"万妖图录传：月落镇魔第四季","episode_cnt":40}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7640559999361485848","title":"万妖图录传：月落镇魔第五季","episode_cnt":60}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7673445881860852761","title":"万妖图录传：月落镇魔第六季","episode_cnt":106}]},{"show_type":659,"search_ip_card_content_type":21,"subscribe_items":[{"item_id":7674507372072537150,"name":"万妖图录传第7季"}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7673736555244031038","title":"镇魔万妖录第一季","episode_cnt":80}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7678373588520406040","title":"镇魔万妖录第二部","episode_cnt":74}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7679319847687162942","title":"镇魔万妖录第三季","episode_cnt":82}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7625132159526767640","title":"姜大人的万妖图录传","episode_cnt":80}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7626703075843001369","title":"镇魔少女","episode_cnt":89}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7631140628499287065","title":"百妖谱在手，从流放到长公主","episode_cnt":72}]},{"show_type":659,"search_ip_card_content_type":2,"video_data":[{"series_id":"7670095309371886654","title":"万妖绘卷，少女斩妖除魔","episode_cnt":70}]}]}]}''')
    as Map<String, dynamic>;

Map<String, dynamic> v3Fixture({bool embedded = true}) {
  final groups = fixture()['cell_data'] as List;
  final docs = (groups.first as Map)['cell_data'] as List;
  return {
    'show_type': 657,
    'cell_name': '万妖图录传',
    'search_ip_card_selected_idx': 12,
    'cell_data': [
      for (var index = 0; index < docs.length; index++)
        {
          'show_type': 658,
          'cell_name': '第${index + 1}季',
          if (docs[index]['video_data'] != null)
            'video_data': [
              {
                ...(docs[index]['video_data'] as List).first as Map,
                'cover': 'https://example.invalid/cover'
              },
            ],
          'cell_data': docs[index]['subscribe_items'] != null
              ? [docs[index]]
              : embedded
                  ? [
                      {
                        'show_type': 659,
                        'search_ip_card_content_type': 22,
                        'cell_name': '原始集数标题',
                        'video_data': [
                          {
                            'series_id': (docs[index]['video_data'] as List)
                                .first['series_id'],
                            'vid': 'episode-${index + 1}',
                            'vid_index': index + 1,
                          }
                        ]
                      },
                    ]
                  : [],
        },
    ],
  };
}

const fixtureSeason13Id = '7690163276214176792';

void main() {
  tearDown(() => DeviceProfile.isTv = false);

  test('真实655保留模块、十三季初始位置和十四季预约，普通369不聚合', () {
    final data = SearchSeriesCardData.tryParse(fixture())!;
    expect(data.title, '万妖图录传');
    expect(data.groups.map((group) => group.title), ['爆款系列', '其他版本']);
    expect(data.groups.first.items, hasLength(14));
    expect(data.groups.first.initialItemIndex, 12);
    expect(data.groups.first.items[12].id, '7690163276214176792');
    expect(data.groups.first.items[12].displayTitle, '第13季');
    expect(data.groups.first.items[13].kind, SearchSeriesItemKind.upcoming);
    expect(data.groups.first.items[13].drama, isNull);
    expect(data.groups[1].items.first.title, '万妖图录传：那妖魔是姜大人');
    for (final type in [369, 393, 656, 657]) {
      expect(SearchSeriesCardData.tryParse({...fixture(), 'show_type': type}),
          isNull);
    }
  });

  test('选择原下标经非法Doc过滤映射，重复作品仍保留原始位置', () {
    final raw = fixture();
    final group = (raw['cell_data'] as List).first as Map<String, dynamic>;
    final items = group['cell_data'] as List;
    items.insert(0,
        {'show_type': 659, 'search_ip_card_content_type': 2, 'video_data': []});
    group['search_ip_card_selected_idx'] = 13;
    items.add(items.firstWhere((item) =>
        (item as Map)['video_data'] is List &&
        (item['video_data'] as List).isNotEmpty));
    final parsed = SearchSeriesCardData.tryParse(raw)!;
    expect(parsed.groups.first.initialItemIndex, 12);
    expect(parsed.groups.first.items[12].id, '7690163276214176792');
    expect(parsed.groups.first.items, hasLength(15));
    expect(
        parsed.groups.first.items.first.id, parsed.groups.first.items.last.id);
    expect(parsed.groups.first.items.first.key,
        isNot(parsed.groups.first.items.last.key));
  });

  test('656只收根659横排，不把658模块递归扁平化', () {
    final source = fixture();
    final docs =
        ((source['cell_data'] as List).first as Map)['cell_data'] as List;
    final data = SearchSeriesCardData.tryParse({
      'show_type': 656,
      'cell_name': '系列原始标题',
      'cell_abstract': '原始副标题',
      'search_ip_card_selected_idx': 12,
      'cell_data': docs,
    })!;
    expect(data.showType, 656);
    expect(data.title, '系列原始标题');
    expect(data.subtitle, '原始副标题');
    expect(data.groups, hasLength(1));
    expect(data.groups.first.initialItemIndex, 12);
    expect(data.groups.first.items[12].title, '万妖图录传第十三季');
    expect(
        SearchSeriesCardData.tryParse({...source, 'show_type': 656}), isNull);
  });

  testWidgets('真实选季锚点显示十三季，点击按真实ID播放且不把其他版本合并', (tester) async {
    final data = SearchSeriesCardData.tryParse(fixture())!;
    Drama? played;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 420,
                child: SearchSeriesCard(
                    data: data, onPlay: (drama) => played = drama)))));
    await tester.pumpAndSettle();
    final selected = find.byKey(const ValueKey('search-series-item-0-12'));
    expect(selected.hitTestable(), findsOneWidget);
    await tester.tap(selected);
    expect(played?.id.toString(), '7690163276214176792');
    await tester.tap(find.byKey(const ValueKey('search-series-group-1')));
    await tester.pumpAndSettle();
    expect(find.text('万妖图录传：那妖魔是姜大人'), findsOneWidget);
    expect(find.text('第13季'), findsNothing);
  });

  testWidgets('TV从首季左右到屏外十三季，横向边界停留且向下可离开', (tester) async {
    DeviceProfile.isTv = true;
    final raw = fixture();
    ((raw['cell_data'] as List).first as Map)['search_ip_card_selected_idx'] =
        0;
    final data = SearchSeriesCardData.tryParse(raw)!;
    final entry = FocusNode();
    final below = FocusNode();
    addTearDown(entry.dispose);
    addTearDown(below.dispose);
    Drama? played;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      SizedBox(
          width: 420,
          child: SearchSeriesCard(
              data: data, focusNode: entry, onPlay: (drama) => played = drama)),
      TextButton(
          focusNode: below, onPressed: () {}, child: const Text('下一条结果')),
    ]))));
    entry.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(entry.hasPrimaryFocus, isTrue);
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    final item13 = find.byKey(const ValueKey('search-series-item-0-12'));
    expect(tester.widget<TvTap>(item13).focusNode!.hasPrimaryFocus, isTrue);
    expect(item13.hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(played?.id.toString(), '7690163276214176792');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final upcoming = find.byKey(const ValueKey('search-series-item-0-13'));
    final upcomingNode = tester.widget<TvTap>(upcoming).focusNode!;
    expect(upcomingNode.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(upcomingNode.hasPrimaryFocus, isTrue);
    played = null;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(played, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(below.hasPrimaryFocus, isTrue);
  });
  testWidgets('TV系统返回能关闭搜索路由，不被横排焦点吞掉', (tester) async {
    DeviceProfile.isTv = true;
    final data = SearchSeriesCardData.tryParse(fixture())!;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return Scaffold(
          body: TextButton(
              onPressed: () {
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) {
                  return Scaffold(
                      body: SearchSeriesCard(data: data, onPlay: (_) {}));
                }));
              },
              child: const Text('打开搜索')));
    })));
    await tester.tap(find.text('打开搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchSeriesCard), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SearchSeriesCard), findsNothing);
    expect(find.text('打开搜索'), findsOneWidget);
  });

  testWidgets('655 TV用遥控确认键切模块，上下进入季横排并按真实ID播放', (tester) async {
    DeviceProfile.isTv = true;
    final data = SearchSeriesCardData.tryParse(fixture())!;
    Drama? played;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 420,
                child: SearchSeriesCard(
                    data: data, onPlay: (drama) => played = drama)))));
    await tester.pumpAndSettle();
    final firstGroup = find.byKey(const ValueKey('search-series-group-0'));
    final otherGroup = find.byKey(const ValueKey('search-series-group-1'));
    // 仅设置顶部分组的初始焦点；后续进入内容与返回均由遥控方向键完成。
    tester.widget<TvTap>(firstGroup).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.widget<TvTap>(otherGroup).focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('search-series-item-1-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-series-item-0-12')), findsNothing);
    expect(played, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    // 默认方向遍历按几何位置进入当前模块的就近条目，再用左键到达首项。
    expect(
        tester
            .widgetList<TvTap>(find.byType(TvTap))
            .where((tap) => tap.focusNode?.hasPrimaryFocus ?? false)
            .any((tap) => tap.key.toString().contains('search-series-item-1-')),
        isTrue);
    for (var index = 0; index < data.groups[1].items.length; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
    }
    final firstItem = find.byKey(const ValueKey('search-series-item-1-0'));
    expect(tester.widget<TvTap>(firstItem).focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(played?.id.toString(), '7656652779691183128');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final secondItem = find.byKey(const ValueKey('search-series-item-1-1'));
    expect(tester.widget<TvTap>(secondItem).focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(played?.id.toString(), '7617687367452724249');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(tester.widget<TvTap>(otherGroup).focusNode!.hasPrimaryFocus, isTrue);
  });
  test('657季和集数分层，预约不变可播，原始索引经过过滤', () {
    final raw = v3Fixture();
    final cells = raw['cell_data'] as List;
    cells.insert(0, {
      'show_type': 658,
      'cell_data': [
        {
          'show_type': 659,
          'search_ip_card_content_type': 0,
          'book_data': [
            {'book_id': 'novel'}
          ]
        },
      ]
    });
    raw['search_ip_card_selected_idx'] = 13;
    final data = SearchSeriesCardData.tryParse(raw)!;
    expect(data.sourceType, 657);
    expect(data.groups, isEmpty);
    expect(data.v3!.seasons, hasLength(14));
    expect(data.v3!.initialSeasonIndex, 12);
    final season = data.v3!.seasons[12];
    expect(season.drama!.id.toString(), fixtureSeason13Id);
    expect(season.episodes.single.vid, 'episode-13');
    expect(season.episodes.single.number, 13);
    expect(data.v3!.seasons.last.isUpcoming, isTrue);
    expect(data.v3!.seasons.last.episodes, isEmpty);
    expect(
        SearchSeriesEpisode.tryParse(
            {'vid': 'vid', 'series_id': 'real', 'vid_index': 0}),
        isNull);
    expect(
        SearchSeriesEpisode.tryParse(
            {'vid': '', 'series_id': 'real', 'vid_index': 1}),
        isNull);
  });

  testWidgets('657切季不直接播，点击集数使用该季真实ID和原始集数', (tester) async {
    final data = SearchSeriesCardData.tryParse(v3Fixture())!;
    String? played;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 420,
                child: SearchSeriesCard(
                    data: data,
                    onPlay: (_) {},
                    onPlayEpisode: (drama, number) =>
                        played = '${drama.id}:$number')))));
    await tester.pumpAndSettle();
    // 当前列表仅一项，其真实 vid_index 为 13，展示与点击都不能按位置变成 1。
    final episode = find.byKey(const ValueKey('search-series-v3-episode-0'));
    expect(find.descendant(of: episode, matching: find.text('13')),
        findsOneWidget);
    expect(find.text('原始集数标题'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('search-series-v3-episode-0')));
    expect(played, '$fixtureSeason13Id:13');
    played = null;
    final first = find.byKey(const ValueKey('search-series-v3-season-0'));
    await tester.ensureVisible(first);
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(played, isNull);
    expect(
        find.descendant(of: episode, matching: find.text('1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-series-v3-episode-0')));
    expect(played, '7621200213801176126:1');
  });

  testWidgets('657附加请求失序不会把旧季集数覆盖到新季，失败可重试', (tester) async {
    final raw = v3Fixture(embedded: false);
    raw['search_ip_card_selected_idx'] = 0;
    final data = SearchSeriesCardData.tryParse(raw)!;
    final requests = <Completer<List<SearchSeriesEpisode>>>[];
    final requested = <SearchSeriesSeason>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 420,
                child: SearchSeriesCard(
                    data: data,
                    onPlay: (_) {},
                    onLoadSeason: (season) {
                      requested.add(season);
                      final result = Completer<List<SearchSeriesEpisode>>();
                      requests.add(result);
                      return result.future;
                    })))));
    await tester.pump();
    expect(requested.first.seriesId, '7621200213801176126');
    await tester.tap(find.byKey(const ValueKey('search-series-v3-season-1')));
    await tester.pump();
    requests[0].complete([
      SearchSeriesEpisode(
          vid: 'old',
          seriesId: requested[0].seriesId,
          number: 99,
          title: '旧季不应出现',
          raw: const {})
    ]);
    requests[1].completeError(StateError('network failed'));
    await tester.pumpAndSettle();
    expect(find.text('99'), findsNothing);
    expect(
        find.byKey(const ValueKey('search-series-v3-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-series-v3-retry')));
    await tester.pump();
    expect(requests, hasLength(3));
    requests[2].complete([
      SearchSeriesEpisode(
          vid: 'new',
          seriesId: requested[2].seriesId,
          number: 2,
          title: '新季正确集数',
          raw: const {})
    ]);
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('search-series-v3-episode-0')),
            matching: find.text('2')),
        findsOneWidget);
    expect(find.text('99'), findsNothing);
  });

  testWidgets('657 TV从封面上下进入季和集，遥控确认切十三季并播放真实集数', (tester) async {
    DeviceProfile.isTv = true;
    final raw = v3Fixture();
    raw['search_ip_card_selected_idx'] = 0;
    final data = SearchSeriesCardData.tryParse(raw)!;
    final hero = FocusNode();
    addTearDown(hero.dispose);
    String? played;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 420,
                child: SearchSeriesCard(
                    data: data,
                    focusNode: hero,
                    onPlay: (_) {},
                    onPlayEpisode: (drama, number) =>
                        played = '${drama.id}:$number')))));
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('search-series-v3-season-0'));
    // 只设置入口 Hero 焦点，不跳过 Hero→季→集的实际方向路径。
    hero.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<TvTap>(find.byType(TvTap))
            .where((tap) => tap.focusNode?.hasPrimaryFocus ?? false)
            .any((tap) =>
                tap.key.toString().contains('search-series-v3-season-')),
        isTrue);
    for (var index = 0; index < data.v3!.seasons.length; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
    }
    expect(tester.widget<TvTap>(first).focusNode!.hasPrimaryFocus, isTrue);
    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    final season13 = find.byKey(const ValueKey('search-series-v3-season-12'));
    expect(tester.widget<TvTap>(season13).focusNode!.hasPrimaryFocus, isTrue);
    expect(season13.hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(played, isNull);
    final episode = find.byKey(const ValueKey('search-series-v3-episode-0'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.widget<TvTap>(episode).focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(played, '$fixtureSeason13Id:13');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    // 返回季横排由几何位置选择就近按钮，移焦本身不会更换当前季。
    expect(
        tester
            .widgetList<TvTap>(find.byType(TvTap))
            .where((tap) => tap.focusNode?.hasPrimaryFocus ?? false)
            .any((tap) =>
                tap.key.toString().contains('search-series-v3-season-')),
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(hero.hasPrimaryFocus, isTrue);
  });
}
