import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/search_suggestion.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/search_suggestion_tile.dart';
import 'package:shortplay/widgets/tv_tap.dart';

SearchSuggestion _suggestion({bool rich = false, bool play = false}) =>
    SearchSuggestion.fromJson({
      'name': '万妖',
      'keyword': 'season-13',
      'show_type': rich ? 3 : 0,
      'can_play': play,
      'has_play_button': play,
      'video_data': {
        'series_id': '7690163276214176792',
        'title': '万妖',
        if (rich) 'cover': 'https://example.invalid/season-cover.jpg',
      },
    });

void main() {
  for (final tv in [false, true]) {
    for (final rich in [false, true]) {
      for (final play in [false, true]) {
        testWidgets(
            '${tv ? 'TV' : '手机'}${rich ? '富卡' : '普通词条'}搜索区域空白和图标均可点击，独立播放不搜索$play',
            (tester) async {
          final wasTv = DeviceProfile.isTv;
          DeviceProfile.isTv = tv;
          addTearDown(() => DeviceProfile.isTv = wasTv);
          var searches = 0;
          var plays = 0;
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: 600,
                  child: SearchSuggestionTile(
                    suggestion: _suggestion(rich: rich, play: play),
                    onSearch: () => searches++,
                    onPlay: () => plays++,
                  ),
                ),
              ),
            ),
          ));
          await tester.pumpAndSettle();
          final actions = find.descendant(
            of: find.byType(SearchSuggestionTile),
            matching: find.byType(TvTap),
          );
          final searchRect = tester.getRect(actions.first);
          final searchPoints = [
            searchRect.center,
            Offset(searchRect.center.dx, searchRect.top + 1),
            Offset(searchRect.center.dx, searchRect.bottom - 1),
            Offset(searchRect.left + 1, searchRect.center.dy),
            Offset(searchRect.right - 1, searchRect.center.dy),
            tester.getCenter(find.byIcon(Icons.chevron_right_rounded)),
            tester.getCenter(
                rich ? find.byType(Image) : find.byIcon(Icons.search_rounded)),
          ];
          for (var i = 0; i < searchPoints.length; i++) {
            await tester.tapAt(searchPoints[i]);
            await tester.pump();
            expect(searches, i + 1,
                reason: '搜索区域第 $i 个点 ${searchPoints[i]} 应命中整行');
            expect(plays, 0);
          }
          if (play) {
            final playRect = tester.getRect(actions.last);
            expect(playRect.top, searchRect.top);
            expect(playRect.bottom, searchRect.bottom);
            final playPoints = [
              playRect.center,
              Offset(playRect.center.dx, playRect.top + 1),
              Offset(playRect.center.dx, playRect.bottom - 1),
              Offset(playRect.right - 1, playRect.center.dy),
              tester.getCenter(find.byIcon(Icons.play_circle_outline)),
            ];
            for (var i = 0; i < playPoints.length; i++) {
              await tester.tapAt(playPoints[i]);
              await tester.pump();
              expect(plays, i + 1);
              expect(searches, searchPoints.length);
            }
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets('TV 整行显示焦点框，播放按钮左右切换并可上下到相邻行', (tester) async {
    final wasTv = DeviceProfile.isTv;
    DeviceProfile.isTv = true;
    addTearDown(() => DeviceProfile.isTv = wasTv);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var searches = 0;
    var plays = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            SearchSuggestionTile(
              suggestion: _suggestion(play: true),
              focusNode: first,
              onSearch: () => searches++,
              onPlay: () => plays++,
            ),
            SearchSuggestionTile(
              suggestion: _suggestion(),
              focusNode: second,
              onSearch: () => searches++,
            ),
          ],
        ),
      ),
    ));
    first.requestFocus();
    await tester.pumpAndSettle();
    final firstTile = find.byType(SearchSuggestionTile).first;
    final searchAction =
        find.descendant(of: firstTile, matching: find.byType(TvTap)).first;
    final focusedDecoration = tester
        .widget<AnimatedContainer>(find.descendant(
          of: searchAction,
          matching: find.byType(AnimatedContainer),
        ))
        .foregroundDecoration as BoxDecoration?;
    expect(focusedDecoration?.border, isNotNull);
    expect(tester.getSize(searchAction).width, greaterThan(500));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('播放'))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(plays, 1);
    expect(searches, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(first.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(second.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(first.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(searches, 1);
    expect(plays, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
