import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/playback_record.dart';
import 'package:shortplay/pages/home/continue_watching_bar.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/playback_history_store.dart';

PlaybackRecord _record(int id,
        {int episodeIndex = 0,
        int positionMs = 0,
        int? durationMs,
        int? episodeCount,
        int updatedAtMs = 1}) =>
    PlaybackRecord(
      dramaId: id,
      dramaName: '剧$id',
      cover: '',
      episodeIndex: episodeIndex,
      episodeNumber: episodeIndex + 1,
      positionMs: positionMs,
      durationMs: durationMs,
      episodeCount: episodeCount,
      updatedAtMs: updatedAtMs,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('播放记录保存时长和总集数，并能算出单集进度', () {
    final record = PlaybackRecord.fromJson(
        _record(1, positionMs: 30000, durationMs: 120000, episodeCount: 80)
            .toJson());
    expect(record.durationMs, 120000);
    expect(record.episodeCount, 80);
    expect(record.episodeProgress, closeTo(0.25, 1e-9));
    // 旧记录没有时长：不显示进度
    expect(
        PlaybackRecord.fromJson(_record(2).toJson()).episodeProgress, isNull);
  });

  test('同一集的进度更新沿用已知时长，并通知监听者', () async {
    var notified = 0;
    void listener() => notified++;
    PlaybackHistoryStore.revision.addListener(listener);
    addTearDown(() => PlaybackHistoryStore.revision.removeListener(listener));

    await PlaybackHistoryStore.upsert(
        _record(7, episodeIndex: 3, durationMs: 90000, episodeCount: 60));
    await PlaybackHistoryStore.upsert(
        _record(7, episodeIndex: 3, positionMs: 45000, updatedAtMs: 2));

    final saved = (await PlaybackHistoryStore.load()).single;
    expect(saved.positionMs, 45000);
    expect(saved.durationMs, 90000);
    expect(saved.episodeCount, 60);
    expect(notified, 2);
  });

  Future<void> pumpBar(WidgetTester tester, {bool active = true}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ContinueWatchingBar(apiClient: ApiClient(), active: active),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder bar() => find.text('继续观看');

  bool barVisible(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity == 1;

  Future<void> pumpFocusableBar(
    WidgetTester tester, {
    required ApiClient api,
    required ValueNotifier<bool> active,
    required FocusNode outsideFocus,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextButton(
            focusNode: outsideFocus,
            onPressed: () {},
            child: const Text('可见按钮'),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (_, value, __) =>
                    ContinueWatchingBar(apiClient: api, active: value),
              ),
            ),
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<bool> tabToContinue(
      WidgetTester tester, FocusNode outsideFocus) async {
    final continueFocus = Focus.of(tester.element(bar()));
    outsideFocus.requestFocus();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (continueFocus.hasFocus) return true;
    }
    return false;
  }

  bool focusInsideBar() {
    var inside = false;
    FocusManager.instance.primaryFocus?.context
        ?.visitAncestorElements((element) {
      if (element.widget is ContinueWatchingBar) inside = true;
      return !inside;
    });
    return inside;
  }

  Future<void> expectHiddenBarSkipped(
      WidgetTester tester, FocusNode outsideFocus) async {
    expect(barVisible(tester), isFalse);
    expect(focusInsideBar(), isFalse, reason: '隐藏提示条时应移出已经在条内的焦点');
    outsideFocus.requestFocus();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusInsideBar(), isFalse, reason: 'Tab 遍历不能进入隐藏的提示条或其关闭、继续观看按钮');
    }
  }

  testWidgets('没有播放记录时不显示继续观看', (tester) async {
    await pumpBar(tester);
    expect(bar(), findsNothing);
  });

  testWidgets('显示最新一部的剧名和集数，8 秒后自动收起且不再出现', (tester) async {
    await tester.runAsync(() async {
      await PlaybackHistoryStore.upsert(_record(1, episodeIndex: 1));
      await PlaybackHistoryStore.upsert(
          _record(9, episodeIndex: 4, updatedAtMs: 2));
    });
    await pumpBar(tester);
    expect(bar(), findsOneWidget);
    expect(find.textContaining('剧9'), findsOneWidget);
    expect(find.textContaining('第5集'), findsOneWidget);
    expect(barVisible(tester), isTrue);

    await tester.pump(ContinueWatchingBar.defaultDisplayDuration);
    await tester.pumpAndSettle();
    expect(barVisible(tester), isFalse);

    // 之后再有新的播放记录也不重新弹出
    await tester.runAsync(() => PlaybackHistoryStore.upsert(
        _record(3, episodeIndex: 0, updatedAtMs: 3)));
    await tester.pumpAndSettle();
    expect(barVisible(tester), isFalse);
  });

  testWidgets('点关闭立即收起', (tester) async {
    await tester.runAsync(() => PlaybackHistoryStore.upsert(_record(5)));
    await pumpBar(tester);
    expect(barVisible(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey('continue-watching-close')));
    await tester.pumpAndSettle();
    expect(barVisible(tester), isFalse);
  });

  testWidgets('不在首页 tab 时不显示，也不开始倒计时', (tester) async {
    await tester.runAsync(() => PlaybackHistoryStore.upsert(_record(5)));
    await pumpBar(tester, active: false);
    expect(barVisible(tester), isFalse);

    await tester.pump(ContinueWatchingBar.defaultDisplayDuration * 2);
    await pumpBar(tester);
    expect(barVisible(tester), isTrue);

    await tester.pump(ContinueWatchingBar.defaultDisplayDuration);
    await tester.pumpAndSettle();
  });

  testWidgets('可见时可用键盘选择续播，切换栏目隐藏后移出焦点并跳过整个提示条', (tester) async {
    await tester.runAsync(() => PlaybackHistoryStore.upsert(_record(5)));
    final api = ApiClient();
    final active = ValueNotifier(true);
    final outsideFocus = FocusNode();
    try {
      await pumpFocusableBar(tester,
          api: api, active: active, outsideFocus: outsideFocus);
      expect(await tabToContinue(tester, outsideFocus), isTrue);
      expect(focusInsideBar(), isTrue);

      active.value = false;
      await tester.pumpAndSettle();
      await expectHiddenBarSkipped(tester, outsideFocus);

      active.value = true;
      await tester.pumpAndSettle();
      expect(await tabToContinue(tester, outsideFocus), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      api.dispose();
      active.dispose();
      outsideFocus.dispose();
    }
  });

  for (final closeManually in [false, true]) {
    testWidgets('${closeManually ? '手动关闭' : '自动收起'}后键盘不能再聚焦提示条',
        (tester) async {
      await tester.runAsync(() => PlaybackHistoryStore.upsert(_record(5)));
      final api = ApiClient();
      final active = ValueNotifier(true);
      final outsideFocus = FocusNode();
      try {
        await pumpFocusableBar(tester,
            api: api, active: active, outsideFocus: outsideFocus);
        expect(await tabToContinue(tester, outsideFocus), isTrue);
        if (closeManually) {
          await tester
              .tap(find.byKey(const ValueKey('continue-watching-close')));
        } else {
          await tester.pump(ContinueWatchingBar.defaultDisplayDuration);
        }
        await tester.pumpAndSettle();
        await expectHiddenBarSkipped(tester, outsideFocus);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        api.dispose();
        active.dispose();
        outsideFocus.dispose();
      }
    });
  }
}
