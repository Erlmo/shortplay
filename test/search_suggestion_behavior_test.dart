import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/search_source.dart';
import 'package:shortplay/models/search_suggestion.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/search_suggestion_tile.dart';

Map<String, dynamic> _suggestion({
  bool canPlay = true,
  bool hasPlayButton = false,
  bool hasVideo = true,
}) =>
    {
      'name': '万妖图录传第十三季',
      'keyword': '7690163276214176792',
      'search_source_id': 'sug-source-token',
      'client_extra': '{"scene":"original"}',
      'show_type': 3,
      'can_play': canPlay,
      'has_play_button': hasPlayButton,
      if (hasVideo)
        'video_data': <String, dynamic>{
          'series_id': '7690163276214176792',
          'title': '万妖图录传第十三季',
        },
    };

void main() {
  test('联想保留完整季名、真实来源与不透明上下文', () {
    final item = SearchSuggestion.fromJson(_suggestion(),
        source: SearchSource.shortplay);
    expect(item.name, '万妖图录传第十三季');
    expect(item.keyword, '7690163276214176792');
    expect(item.searchSourceId, 'sug-source-token');
    expect(item.clientExtra, '{"scene":"original"}');
    expect(item.source, SearchSource.shortplay);
    expect(item.drama?.id, 7690163276214176792);

    expect(item.showPlayButton, isFalse);
  });

  test('可播放卡有独立按钮时整行搜索，按钮播放', () {
    final item = SearchSuggestion.fromJson(_suggestion(hasPlayButton: true));

    expect(item.showPlayButton, isTrue);
  });

  test('没有真实视频数据的普通词条不将keyword当播放ID', () {
    final item = SearchSuggestion.fromJson(_suggestion(hasVideo: false));
    expect(item.drama, isNull);

    expect(item.showPlayButton, isFalse);
  });

  test('use_rich关闭时忽略返回的播放标记并保留请求来源', () {
    final item = SearchSuggestionResult.fromJson({
      'query_key': '万妖',
      'use_rich': false,
      'query_result_v2': [_suggestion(hasPlayButton: true)],
    }, source: SearchSource.shortplay)
        .items
        .single;
    expect(item.source, SearchSource.shortplay);

    expect(item.showPlayButton, isFalse);
    expect(item.name, '万妖图录传第十三季');
  });

  test('旧字符串联想继承搜索来源', () {
    final result = SearchSuggestionResult.fromJson({
      'query_key': '万妖',
      'query_result': ['万妖图录传第十三季'],
    }, source: SearchSource.shortplay);
    expect(result.items.single.source, SearchSource.shortplay);
  });

  test('真实顶层series_id优先，不能被旧详情ID替换成第一季', () {
    final json = _suggestion();
    (json['video_data'] as Map)['video_detail'] = {'series_id': '123456'};
    final item = SearchSuggestion.fromJson(json);
    expect(item.drama?.id, 7690163276214176792);
  });

  for (final tv in [false, true]) {
    for (final hasPlayButton in [false, true]) {
      testWidgets('${tv ? 'TV' : '手机'}联想整行与独立播放入口正确分流$hasPlayButton',
          (tester) async {
        final wasTv = DeviceProfile.isTv;
        DeviceProfile.isTv = tv;
        addTearDown(() => DeviceProfile.isTv = wasTv);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        var searches = 0;
        var plays = 0;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SearchSuggestionTile(
              suggestion: SearchSuggestion.fromJson(
                  _suggestion(hasPlayButton: hasPlayButton)),
              focusNode: focus,
              onSearch: () => searches++,
              onPlay: () => plays++,
            ),
          ),
        ));
        if (tv) {
          focus.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        } else {
          await tester.tap(find.text('万妖图录传第十三季'));
        }
        await tester.pump();
        expect(searches, 1);
        expect(plays, 0);
        if (hasPlayButton) {
          if (tv) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          } else {
            await tester.tap(find.text('播放'));
          }
          await tester.pump();
          expect(searches, 1);
          expect(plays, 1);
          if (tv) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pump();
            expect(focus.hasPrimaryFocus, isTrue);
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
