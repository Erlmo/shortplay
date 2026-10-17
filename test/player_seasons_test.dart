import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/drama_season.dart';
import 'package:shortplay/models/episode.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/widgets/player/episode_sheet.dart';

const _seasons = DramaSeasons(albumId: 'album', currentSeason: 2, seasons: [
  DramaSeason(id: 1, title: '测试第一季', cover: '', order: 1, episodeCount: 50),
  DramaSeason(id: 2, title: '测试第二季', cover: '', order: 2, episodeCount: 60),
  DramaSeason(id: 3, title: '测试第三季', cover: '', order: 3, episodeCount: 70),
]);
final _episodes = List.generate(60,
    (i) => Episode(index: i + 1, name: '第${i + 1}集', url: 'video-$i', size: 0));

void main() {
  setUp(() => DeviceProfile.isTv = false);

  Future<void> open(
    WidgetTester tester, {
    required Future<DramaSeasons> Function() loader,
    required ValueChanged<DramaSeason> onSelect,
    bool landscape = false,
  }) async {
    await tester.binding.setSurfaceSize(
        landscape ? const Size(844, 390) : const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final current = ValueNotifier<int>(2);
    addTearDown(current.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showPlayerEpisodeSheet(
                          context: context,
                          isLandscapeFullScreen: landscape,
                          dramaName: '测试第二季',
                          currentDramaId: 2,
                          episodes: _episodes,
                          episodeNotifier: current,
                          onSelectEpisode: (_) {},
                          loadSeasons: loader,
                          onSelectSeason: onSelect,
                        ),
                    child: const Text('打开选集'))))));
    await tester.tap(find.text('打开选集'));
    await tester.pumpAndSettle();
  }

  for (final landscape in [false, true]) {
    testWidgets('${landscape ? '横屏' : '竖屏'}选集显示总季数，打开相关季并选择后关闭面板',
        (tester) async {
      DramaSeason? selected;
      await open(tester,
          landscape: landscape,
          loader: () async => _seasons,
          onSelect: (season) => selected = season);
      expect(find.text('共3季'), findsOneWidget);
      expect(find.text('序号选集'), findsNothing);
      expect(find.byKey(const ValueKey('episode-2')), findsOneWidget);
      await tester.tap(find.text('共3季'));
      await tester.pumpAndSettle();
      expect(find.text('相关季'), findsOneWidget);
      expect(find.text('正在播放'), findsOneWidget);
      expect(find.text('第1季'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-season-1')));
      await tester.pumpAndSettle();
      expect(selected?.id, 1);
      expect(find.text('相关季'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('选择当前季返回集数，不重新播放或丢失当前集', (tester) async {
    var selected = false;
    await open(tester,
        loader: () async => _seasons, onSelect: (_) => selected = true);
    await tester.tap(find.text('共3季'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-season-2')));
    await tester.pumpAndSettle();
    expect(selected, isFalse);
    expect(find.byKey(const ValueKey('episode-2')), findsOneWidget);
    expect(find.text('共3季'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('相关季失败可重试，正常返回后显示实际季数', (tester) async {
    var calls = 0;
    await open(tester, loader: () async {
      if (++calls == 1) throw ApiException('暂时失败');
      return _seasons;
    }, onSelect: (_) {});
    await tester.tap(find.text('选季'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('相关季加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('测试第三季'), findsOneWidget);
    await tester.tap(find.text('返回选集'));
    await tester.pumpAndSettle();
    expect(find.text('共3季'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没有关联季时保留当前季，关闭面板后迟到响应安全丢弃', (tester) async {
    await open(tester,
        loader: () async =>
            const DramaSeasons(albumId: '', currentSeason: 2, seasons: []),
        onSelect: (_) {});
    expect(find.text('共1季'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    final pending = Completer<DramaSeasons>();
    await open(tester, loader: () => pending.future, onSelect: (_) {});
    await tester.tap(find.text('选季'));
    await tester.pumpAndSettle();
    expect(find.text('正在加载相关季…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(_seasons);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
