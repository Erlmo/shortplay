import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/widgets/detail_action_bar.dart';

void main() {
  testWidgets('窄屏大字体底栏避开安全区，缓存提交时不能重复点击', (tester) async {
    const screen = Size(320, 700);
    await tester.binding.setSurfaceSize(screen);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var plays = 0;
    var downloads = 0;
    var adding = false;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: screen,
          padding: EdgeInsets.only(bottom: 34),
          textScaler: TextScaler.linear(1.3),
        ),
        child: StatefulBuilder(builder: (context, setState) {
          return Scaffold(
            bottomNavigationBar: DetailActionBar(
              onPlay: () => plays++,
              onDownload: () {
                downloads++;
                setState(() => adding = true);
              },
              addingDownloads: adding,
            ),
          );
        }),
      ),
    ));
    final cache = find.widgetWithText(TextButton, '缓存');
    final play = find.widgetWithText(FilledButton, '立即播放');
    expect(tester.getSize(cache).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(play).height, greaterThanOrEqualTo(48));
    expect(tester.getRect(play).bottom, lessThanOrEqualTo(screen.height - 34));
    await tester.tap(play);
    expect(plays, 1);
    await tester.tap(cache);
    await tester.pump();
    final pending = find.widgetWithText(TextButton, '添加中');
    expect(tester.widget<TextButton>(pending).onPressed, isNull);
    await tester.tap(pending);
    await tester.pump();
    expect(downloads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
