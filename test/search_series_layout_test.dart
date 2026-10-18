import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/search_series_card.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/search_series_card.dart';

// 尺寸来自 74032 的 SearchSeriesCardV1/V2Content 与 SeriesCardItemCard；
// 仅构造不带远程封面的协议数据，使测试专注于布局约束和原生色值。
Map<String, dynamic> _doc(int index, {String? displayTitle}) => {
      'show_type': 659,
      'search_ip_card_content_type': 2,
      'search_high_light': {
        'title': {'text': displayTitle ?? '第${index + 1}季'},
      },
      'video_data': [
        {
          'series_id': '${101 + index}',
          'title': '正片第${index + 1}季',
          'episode_cnt': 12 + index,
        },
      ],
    };

SearchSeriesCardData _rail({int type = 655, bool longTitles = false}) {
  final docs = [
    _doc(0,
        displayTitle: longTitles ? '这一季有非常长的完整标题用于确认海报下方保持单行省略而不扩大卡片高度' : null),
    _doc(1),
  ];
  return SearchSeriesCardData.tryParse({
    'show_type': type,
    'cell_name': longTitles ? '一个很长很长的系列作品完整标题需要在有限宽度内省略并保持首行高度不变' : '原始系列',
    if (type == 656) 'cell_abstract': '原始副标题',
    'cell_data': type == 656
        ? docs
        : [
            {'show_type': 658, 'cell_name': '爆款系列', 'cell_data': docs},
            {
              'show_type': 658,
              'cell_name': '其他版本',
              'cell_data': [_doc(2)],
            },
          ],
  })!;
}

SearchSeriesCardData _v3() => SearchSeriesCardData(
      title: '系列季集卡',
      showType: 657,
      groups: const [],
      initialGroupIndex: 0,
      v3: SearchSeriesV3Data(
        title: '系列季集卡',
        subtitle: '',
        initialSeasonIndex: 0,
        seasons: [
          for (var season = 0; season < 2; season++)
            SearchSeriesSeason(
              id: '${201 + season}',
              sourceIndex: season,
              title: '第${season + 1}季',
              seriesId: '${201 + season}',
              drama: null,
              cover: '',
              subtitle: '',
              initialEpisodeIndex: 0,
              subscription: const {},
              raw: const {},
              episodes: [
                for (var episode = 0; episode < 2; episode++)
                  SearchSeriesEpisode(
                    vid: 'vid-$season-$episode',
                    seriesId: '${201 + season}',
                    number: episode + 1,
                    title: '第${episode + 1}集',
                    raw: const {},
                  ),
              ],
            ),
        ],
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  SearchSeriesCardData data, {
  double width = 360,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(MaterialApp(
    // 使用与原生薄荷色相反的项目主色，防止错误回退到 Material 品牌派生色。
    theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.red, brightness: brightness)),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: SearchSeriesCard(data: data, onPlay: (_) {}),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _cover(int index) =>
    find.byKey(ValueKey('search-series-cover-video:${101 + index}:$index'));

Finder _tap(String name) => find.byKey(ValueKey(name));

Container _tapContainer(WidgetTester tester, String name) =>
    tester.widget<Container>(find
        .descendant(
          of: _tap(name),
          matching: find.byType(Container),
        )
        .first);

Color? _background(Container container) =>
    (container.decoration as BoxDecoration).color;

void _expectSize(
    WidgetTester tester, Finder finder, double width, double height) {
  final actual = tester.getSize(finder);
  expect(actual.width, closeTo(width, .01));
  expect(actual.height, closeTo(height, .01));
}

void main() {
  setUp(() => DeviceProfile.isTv = false);
  tearDown(() => DeviceProfile.isTv = false);

  testWidgets('655保持原生封面比例圆角和模块尺寸，不随项目红色主题染色', (tester) async {
    await _pump(tester, _rail());
    final surface = find.byKey(const ValueKey('search-series-surface'));
    expect(_background(tester.widget<Container>(surface)), Colors.white);
    expect(tester.widget<Text>(find.text('原始系列')).style?.color,
        const Color(0xFF00B893));
    expect(tester.widget<Text>(find.text('第1季')).style?.color,
        const Color(0xFF1B1B1B));
    expect(tester.widget<Text>(find.text('第1季')).style?.fontWeight,
        FontWeight.w500);

    _expectSize(tester, _cover(0), 84, 119);
    final clip = tester.widget<ClipRRect>(
        find.ancestor(of: _cover(0), matching: find.byType(ClipRRect)).first);
    expect(clip.borderRadius, BorderRadius.circular(12));
    _expectSize(tester, _tap('search-series-group-0'), 64, 28);
    _expectSize(tester, _tap('search-series-group-1'), 64, 28);
    expect(_background(_tapContainer(tester, 'search-series-group-0')),
        const Color(0x4061F2D0));
    expect(_background(_tapContainer(tester, 'search-series-group-1')),
        const Color(0x08000000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('655的标题模块封面和副标题按原生间距对齐', (tester) async {
    await _pump(tester, _rail());
    final surface =
        tester.getRect(find.byKey(const ValueKey('search-series-surface')));
    final first = tester.getRect(_cover(0));
    final second = tester.getRect(_cover(1));
    final seasonTitle = tester.getRect(find.text('第1季'));
    final subtitle = tester.getRect(find.text('共12集'));

    // 顶16 + 标题槽32 + gap4 + tab28 + rail前12。
    expect(first.top - surface.top, closeTo(92, .01));
    expect(first.left - surface.left, closeTo(16, .01));
    expect(second.left - first.right, closeTo(8, .01));
    expect(seasonTitle.top - first.bottom, closeTo(8, .01));
    expect(seasonTitle.height, closeTo(20, .01));
    expect(subtitle.top - seasonTitle.bottom, closeTo(4, .01));
    expect(subtitle.height, closeTo(17, .01));
    expect(surface.bottom - subtitle.bottom, closeTo(16, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('656标题简介紧凑排列，没有655额外的32高标题槽', (tester) async {
    await _pump(tester, _rail(type: 656));
    final surface =
        tester.getRect(find.byKey(const ValueKey('search-series-surface')));
    final title = tester.getRect(find.text('原始系列'));
    final subtitle = tester.getRect(find.text('原始副标题'));
    final cover = tester.getRect(_cover(0));

    expect(title.top - surface.top, closeTo(13, .01));
    expect(title.height, closeTo(22, .01));
    expect(subtitle.top - title.bottom, closeTo(2, .01));
    expect(subtitle.height, closeTo(17, .01));
    expect(cover.top - subtitle.bottom, closeTo(12, .01));
    expect(cover.left, closeTo(title.left, .01));
    expect(find.byKey(const ValueKey('search-series-group-0')), findsNothing);
    expect(tester.widget<Text>(find.text('原始系列')).style?.fontSize, 16);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV放大保留112宽封面及模块和间距的统一比例', (tester) async {
    DeviceProfile.isTv = true;
    await _pump(tester, _rail(), width: 600);
    final surface =
        tester.getRect(find.byKey(const ValueKey('search-series-surface')));
    final cover = tester.getRect(_cover(0));
    const scale = 4 / 3;

    _expectSize(tester, _cover(0), 112, 119 * scale);
    _expectSize(tester, _tap('search-series-group-0'), 64 * scale, 28 * scale);
    expect(cover.left - surface.left, closeTo(16 * scale, .01));
    expect(cover.top - surface.top, closeTo(92 * scale, .01));
    final clip = tester.widget<ClipRRect>(
        find.ancestor(of: _cover(0), matching: find.byType(ClipRRect)).first);
    expect(clip.borderRadius, BorderRadius.circular(16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色系列卡使用原生中性底色与host薄荷选中色', (tester) async {
    await _pump(tester, _rail(), brightness: Brightness.dark);
    expect(
        _background(tester.widget<Container>(
            find.byKey(const ValueKey('search-series-surface')))),
        const Color(0xFF1C1C1C));
    expect(_background(_tapContainer(tester, 'search-series-group-0')),
        const Color(0x2661F2D0));
    expect(_background(_tapContainer(tester, 'search-series-group-1')),
        const Color(0x0FFFFFFF));
    expect(tester.widget<Text>(find.text('第1季')).style?.color, Colors.white);
    expect(tester.takeException(), isNull);
  });

  testWidgets('657封面突出后景十六且简介按钮底部对齐，季集区域独立衔接', (tester) async {
    await _pump(tester, _v3());
    final hero = _tap('search-series-v3-hero');
    final cover =
        find.descendant(of: hero, matching: find.byType(ClipRRect)).first;
    final backdrop = find.byKey(const ValueKey('search-series-v3-backdrop'));
    _expectSize(tester, cover, 114, 160);
    final coverRect = tester.getRect(cover);
    final backdropRect = tester.getRect(backdrop);
    expect(backdropRect.top - coverRect.top, closeTo(16, .01));
    final button = find
        .ancestor(of: find.text('播放'), matching: find.byType(Container))
        .first;
    expect(tester.getRect(button).bottom, closeTo(coverRect.bottom, .01));
    expect(tester.getRect(button).height, closeTo(32, .01));
    final season = tester.getRect(_tap('search-series-v3-season-0'));
    final episode = tester.getRect(_tap('search-series-v3-episode-0'));
    expect(season.top - coverRect.bottom, closeTo(9 + 7, .01));
    expect(episode.top - season.bottom, closeTo(13, .01));
    expect(backdropRect.bottom - episode.bottom, closeTo(12, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('657仅当前季使用薄荷选中色，集数格保持通用中性底色', (tester) async {
    await _pump(tester, _v3());
    final seasonText = tester.widget<Text>(find
        .descendant(
            of: _tap('search-series-v3-season-0'), matching: find.byType(Text))
        .first);
    expect(seasonText.maxLines, 1);
    expect(seasonText.overflow, TextOverflow.ellipsis);
    expect(_background(_tapContainer(tester, 'search-series-v3-season-0')),
        const Color(0x4061F2D0));
    expect(_background(_tapContainer(tester, 'search-series-v3-season-1')),
        const Color(0x08000000));
    for (var episode = 0; episode < 2; episode++) {
      expect(
          _background(
              _tapContainer(tester, 'search-series-v3-episode-$episode')),
          const Color(0x08000000));
      _expectSize(tester, _tap('search-series-v3-episode-$episode'), 53, 52);
    }
    await tester.tap(_tap('search-series-v3-season-1'));
    await tester.pumpAndSettle();
    expect(_background(_tapContainer(tester, 'search-series-v3-season-1')),
        const Color(0x4061F2D0));
    expect(_background(_tapContainer(tester, 'search-series-v3-episode-0')),
        const Color(0x08000000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('极长系列和季标题保持单行省略，有限宽度下不挤压封面或溢出', (tester) async {
    final data = _rail(longTitles: true);
    await _pump(tester, data, width: 240);
    final title = tester.widget<Text>(find.text(data.title));
    final seasonTitle = tester
        .widget<Text>(find.text(data.groups.first.items.first.displayTitle));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(seasonTitle.maxLines, 1);
    expect(seasonTitle.overflow, TextOverflow.ellipsis);
    expect(tester.getSize(find.text(data.title)).width, lessThanOrEqualTo(208));
    expect(
        tester
            .getSize(find.text(data.groups.first.items.first.displayTitle))
            .width,
        lessThanOrEqualTo(84));
    _expectSize(tester, _cover(0), 84, 119);
    expect(tester.takeException(), isNull);
  });
}
