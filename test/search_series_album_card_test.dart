import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/search_results.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/search_series_album_card.dart';
import 'package:shortplay/widgets/tv_tap.dart';

Drama _drama(int id, String name) => Drama(
    id: id,
    name: name,
    actors: '',
    cover: '',
    intro: '',
    tags: const [],
    status: '',
    updateTime: '',
    isTheaterResource: true);

SearchSeriesAlbum _album({bool invalidPlayable = false}) => SearchSeriesAlbum(
      preview: _drama(109, '命中作品真实标题'),
      moduleTitle: '原始系列标题',
      items: [
        for (var i = 1; i <= 13; i++)
          SearchSeriesItem(
            id: i == 3 ? 'reserved-item-xyz' : '${100 + i}',
            title: i == 3 ? '番外终章（预约）' : '原始作品标题$i',
            cover: '',
            isPlayable: i != 3,
            drama: i == 3 || (invalidPlayable && i == 4)
                ? null
                : _drama(100 + i, '原始作品标题$i'),
            routeUrl:
                i == 3 ? 'dragon8662://subscribe?id=reserved-item-xyz' : '',
          )
      ],
    );

void main() {
  tearDown(() => DeviceProfile.isTv = false);

  Future<void> open(WidgetTester tester,
      {ValueChanged<Drama>? onPlay,
      SearchSeriesAlbum? album,
      FocusNode? focusNode}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SearchSeriesAlbumCard(
              album: album ?? _album(),
              onPlay: onPlay ?? (_) {},
              focusNode: focusNode,
            ),
          )),
    )));
    await tester.pumpAndSettle();
  }

  Finder more() => find.byKey(const ValueKey('series-album-more-109'));
  Finder item(String key) => find.byKey(ValueKey('series-album-item-$key'));
  bool focused(WidgetTester tester, Finder finder) =>
      tester.widget<TvTap>(finder).focusNode!.hasPrimaryFocus;

  testWidgets('小预览保留真实命中ID与标题，预览不默认播放第一季', (tester) async {
    Drama? selected;
    await open(tester, onPlay: (drama) => selected = drama);
    expect(find.text('共13季'), findsOneWidget);
    expect(find.text('命中作品真实标题'), findsOneWidget);
    expect(find.byType(TvTap), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('series-album-preview-109')));
    await tester.pumpAndSettle();
    expect(selected!.id, 109);
    expect(
        find.byKey(const ValueKey('series-album-panel-scroll')), findsNothing);
  });

  testWidgets('面板保留原始顺序与真实标题，预约条目不伪装为可播季', (tester) async {
    Drama? selected;
    await open(tester, onPlay: (drama) => selected = drama);
    await tester.tap(more());
    await tester.pumpAndSettle();
    expect(find.text('原始系列标题'), findsOneWidget);
    expect(find.text('番外终章（预约）'), findsOneWidget);
    expect(find.text('第3季'), findsNothing);
    expect(find.text('待上线'), findsOneWidget);
    expect(tester.getTopLeft(item('playable:102')).dy,
        lessThan(tester.getTopLeft(item('reservable:reserved-item-xyz')).dy));
    expect(tester.getTopLeft(item('reservable:reserved-item-xyz')).dy,
        lessThan(tester.getTopLeft(item('playable:104')).dy));
    await tester.tap(item('reservable:reserved-item-xyz'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.byKey(const ValueKey('series-album-panel-scroll')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机滑到13项播放真实ID，关闭面板只回调一次', (tester) async {
    final selected = <int>[];
    await open(tester, onPlay: (drama) => selected.add(drama.id));
    await tester.tap(more());
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('series-album-panel-scroll')),
        const Offset(0, -1800));
    await tester.pumpAndSettle();
    await tester.tap(item('playable:113'));
    await tester.pumpAndSettle();
    expect(selected, [113]);
    expect(
        find.byKey(const ValueKey('series-album-panel-scroll')), findsNothing);
  });

  testWidgets('TV预览向下到更多，所有条目含预约可到屏外13项确认', (tester) async {
    DeviceProfile.isTv = true;
    final previewFocus = FocusNode();
    addTearDown(previewFocus.dispose);
    final selected = <int>[];
    await open(tester,
        focusNode: previewFocus, onPlay: (drama) => selected.add(drama.id));
    previewFocus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(tester, more()), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(focused(tester, item('playable:101')), isTrue);
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      if (i == 1) {
        expect(focused(tester, item('reservable:reserved-item-xyz')), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, isEmpty);
      }
    }
    expect(focused(tester, item('playable:113')), isTrue);
    final visible =
        tester.getRect(find.byKey(const ValueKey('series-album-panel-scroll')));
    final last = tester.getRect(item('playable:113'));
    expect(last.top, greaterThanOrEqualTo(visible.top));
    expect(last.bottom, lessThanOrEqualTo(visible.bottom));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, [113]);
    expect(focused(tester, more()), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV系统返回与关闭按钮都关闭面板并恢复more焦点', (tester) async {
    DeviceProfile.isTv = true;
    await open(tester);
    await tester.tap(more());
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('series-album-panel-scroll')), findsNothing);
    expect(focused(tester, more()), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final close = find.byKey(const ValueKey('series-album-panel-close'));
    expect(focused(tester, close), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('series-album-panel-scroll')), findsNothing);
    expect(focused(tester, more()), isTrue);
  });

  testWidgets('没有有效Drama的条目绝不以字符串ID合成播放器参数', (tester) async {
    var plays = 0;
    await open(tester,
        album: _album(invalidPlayable: true), onPlay: (_) => plays++);
    await tester.tap(more());
    await tester.pumpAndSettle();
    await tester.ensureVisible(item('playable:104'));
    await tester.tap(item('playable:104'));
    await tester.pumpAndSettle();
    expect(plays, 0);
    expect(find.text('待上线'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('series-album-panel-scroll')),
        findsOneWidget);
  });
}
