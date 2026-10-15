import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/episode.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/episode_selector.dart';
import 'package:shortplay/widgets/tv_drama_detail_view.dart';

void main() {
  testWidgets('电视详情长标题不溢出，确认键播放并可切换分组选择集数', (tester) async {
    DeviceProfile.isTv = true;
    addTearDown(() => DeviceProfile.isTv = false);
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var plays = 0;
    int? selected;
    final drama = Drama.fromJson({
      'id': 1,
      'name': '这是一个足够长的短剧标题，用于确认电视详情页标题换行后仍然可以正常播放和选集',
      'intro': '这是剧情简介。' * 40,
    });
    await tester.pumpWidget(MaterialApp(
        home: TvDramaDetailView(
      drama: drama,
      cover: const ColoredBox(color: Colors.grey),
      onBack: () {},
      onPlay: () => plays++,
      onDownload: () {},
      episodes: EpisodeSelector(
        episodes: List.generate(
            60,
            (index) => Episode(
                  index: index + 1,
                  name: '第${index + 1}集',
                  size: 0,
                  url: '',
                )),
        activeIndex: -1,
        autofocusActive: false,
        horizontalPadding: 0,
        onSelect: (index) => selected = index,
      ),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(Focus.of(tester.element(find.text('立即播放'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(plays, 1);

    Focus.of(tester.element(find.ancestor(
      of: find.text('31-60'),
      matching: find.byType(InkWell),
    ))).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('31'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    Focus.of(tester.element(find.ancestor(
      of: find.text('31'),
      matching: find.byType(InkWell),
    ))).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(selected, 30);
    expect(tester.takeException(), isNull);
  });
}
