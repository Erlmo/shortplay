import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/episode.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/download_service.dart';
import 'package:shortplay/services/player_sleep_timer.dart';
import 'package:shortplay/widgets/player/episode_sheet.dart';
import 'package:shortplay/widgets/player/player_controls_overlay.dart';
import 'package:shortplay/widgets/player/player_video_surface.dart';
import 'package:shortplay/widgets/player/sleep_timer_sheet.dart';

void main() {
  testWidgets('定时到期只触发一次，重新设置替换旧定时', (tester) async {
    var now = DateTime(2026, 9, 30);
    int elapsed = 0;
    final timer = PlayerSleepTimer(onElapsed: () => elapsed++, now: () => now);
    addTearDown(timer.dispose);
    timer.start(const Duration(minutes: 15));
    now = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));
    timer.start(const Duration(minutes: 30));
    now = now.add(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 10));
    expect(elapsed, 0);
    expect(timer.remaining, const Duration(minutes: 20));
    now = now.add(const Duration(minutes: 20));
    await tester.pump(const Duration(minutes: 20));
    timer.checkDeadline();
    expect(elapsed, 1);
    expect(timer.isActive, isFalse);
  });

  testWidgets('取消定时和销毁后不触发停止播放', (tester) async {
    var now = DateTime(2026, 9, 30);
    int elapsed = 0;
    final timer = PlayerSleepTimer(onElapsed: () => elapsed++, now: () => now);
    timer.start(const Duration(minutes: 15));
    timer.cancel();
    now = now.add(const Duration(minutes: 20));
    await tester.pump(const Duration(minutes: 20));
    expect(elapsed, 0);
    timer.start(const Duration(minutes: 15));
    timer.dispose();
    now = now.add(const Duration(minutes: 20));
    await tester.pump(const Duration(minutes: 20));
    expect(elapsed, 0);
  });

  testWidgets('从后台恢复时立即检查截止时间，未到期不提前停止', (tester) async {
    var now = DateTime(2026, 9, 30);
    int elapsed = 0;
    final timer = PlayerSleepTimer(onElapsed: () => elapsed++, now: () => now);
    addTearDown(timer.dispose);
    timer.start(const Duration(minutes: 15));
    now = now.add(const Duration(minutes: 5));
    timer.checkDeadline();
    expect(elapsed, 0);
    now = now.add(const Duration(minutes: 20));
    timer.checkDeadline();
    expect(elapsed, 1);
    expect(timer.remaining, Duration.zero);
  });

  for (final video in [
    const Size(1920, 1080),
    const Size(1440, 1080),
    const Size(1080, 1920)
  ]) {
    testWidgets('全屏 ${video.width}x${video.height} 等比例完整显示并居中', (tester) async {
      const screen = Size(844, 390);
      await tester.binding.setSurfaceSize(screen);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: PlayerVideoSurface(
        textureId: 1,
        videoWidth: video.width.toInt(),
        videoHeight: video.height.toInt(),
        isLandscapeFullScreen: true,
      ))));
      final rect = tester.getRect(find.byType(Texture));
      expect(
          rect.width / rect.height, closeTo(video.width / video.height, 0.001));
      expect(rect.width, lessThanOrEqualTo(screen.width + 0.001));
      expect(rect.height, lessThanOrEqualTo(screen.height + 0.001));
      expect(rect.center.dx, closeTo(screen.width / 2, 0.001));
      expect(rect.center.dy, closeTo(screen.height / 2, 0.001));
      expect(tester.takeException(), isNull);
    });
  }

  for (final video in [const Size(1920, 1080), const Size(1080, 1920)]) {
    testWidgets('竖屏页面 ${video.width}x${video.height} 铺满屏幕', (tester) async {
      const screen = Size(390, 844);
      await tester.binding.setSurfaceSize(screen);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: PlayerVideoSurface(
        textureId: 1,
        videoWidth: video.width.toInt(),
        videoHeight: video.height.toInt(),
        isLandscapeFullScreen: false,
      ))));
      final rect = tester.getRect(find.byType(Texture));
      expect(rect.left, lessThanOrEqualTo(0.001));
      expect(rect.top, lessThanOrEqualTo(0.001));
      expect(rect.right, greaterThanOrEqualTo(screen.width - 0.001));
      expect(rect.bottom, greaterThanOrEqualTo(screen.height - 0.001));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('三点位于集数右侧，小屏菜单提供下载和定时关闭', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final position = ValueNotifier<int>(0);
    final playing = ValueNotifier<bool>(false);
    final duration = ValueNotifier<int>(60000);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);
    addTearDown(duration.dispose);
    PlayerMenuAction? selected;
    Duration? timer;
    int opened = 0;
    int closed = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PlayerControlsOverlay(
      player: null,
      playerInitialized: true,
      isLandscapeFullScreen: false,
      showLandscapeUI: true,
      isPageTransitioning: false,
      isOfflinePlayback: false,
      isTheaterResource: true,
      danmakuEnabled: false,
      isSpeedUp: false,
      userPaused: false,
      currentEpisodeIndex: 2,
      episodeNumber: 15,
      playbackSpeed: 1,
      positionMsNotifier: position,
      playingNotifier: playing,
      durationMsNotifier: duration,
      speedButtonKey: GlobalKey(),
      seekingPositionMs: null,
      onBack: () {},
      onToggleDanmaku: () {},
      onSpeedTap: () {},
      onEpisodeTap: () {},
      onMenuAction: (action) => selected = action,
      onMenuOpened: () => opened++,
      onMenuClosed: () => closed++,
      canDownload: true,
      sleepTimerActive: false,
      onSleepDurationChanged: (value) => timer = value,
      onTogglePlay: () {},
      onToggleLandscapeFullScreen: () {},
      onSeekStart: (_) {},
      onSeekChanged: (_) {},
      onSeekEnd: (_) {},
    ))));
    expect(tester.getCenter(find.byIcon(Icons.more_horiz)).dx,
        greaterThan(tester.getCenter(find.text('第 15 集')).dx));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('更多功能'));
    await tester.pumpAndSettle();
    expect(find.text('下载本地'), findsOneWidget);
    expect(find.text('定时'), findsOneWidget);
    await tester.tap(find.text('下载本地'));
    await tester.pumpAndSettle();
    expect(selected, PlayerMenuAction.download);
    expect(opened, 1);
    expect(closed, 1);
    await tester.tap(find.byTooltip('更多功能'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30分'));
    await tester.pumpAndSettle();
    expect(timer, const Duration(minutes: 30));
    expect(find.text('播放设置'), findsOneWidget);
  });

  testWidgets('定时弹窗返回选定时长并可取消已有定时', (tester) async {
    Duration? selected;
    bool active = false;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        selected = await showSleepTimerSheet(
                            context: context,
                            remaining: const Duration(minutes: 10),
                            isActive: active);
                      },
                      child: const Text('设置')),
                ))));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 分钟'));
    await tester.pumpAndSettle();
    expect(selected, const Duration(minutes: 30));
    active = true;
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('约 10 分钟后停止播放'), findsOneWidget);
    await tester.ensureVisible(find.text('取消定时'));
    await tester.tap(find.text('取消定时'));
    await tester.pumpAndSettle();
    expect(selected, Duration.zero);
  });

  for (final landscape in [false, true]) {
    testWidgets('${landscape ? '横屏' : '竖屏'}下载复用分页选集，可跨组多选且跳过已有缓存',
        (tester) async {
      await tester.binding.setSurfaceSize(
          landscape ? const Size(844, 390) : const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final directory =
          Directory.systemTemp.createTempSync('shortplay-selector-');
      final client = ApiClient();
      final episodes = List.generate(
          35,
          (i) => Episode(
              index: i + 1, name: '第${i + 1}集', size: 0, url: 'v${i + 1}'));
      final localFile = File('${directory.path}/downloads/a/ep_1.mp4');
      localFile.parent.createSync(recursive: true);
      localFile.writeAsBytesSync([1, 2, 3]);
      SharedPreferences.setMockInitialValues({
        'download_state_v3': jsonEncode({
          'version': 3,
          'groups': [
            {
              'dramaId': 'a',
              'dramaName': '测试剧',
              'episodes': [
                {
                  'index': 1,
                  'name': '第一集',
                  'url': 'v1',
                  'status': 'completed',
                  'fileSize': 3
                },
              ]
            },
          ]
        }),
      });
      final gate = Completer<DownloadResolveResult>();
      late DownloadService service;
      await tester.runAsync(() async {
        service = DownloadService(
            apiClient: client, documentsDirectory: () async => directory);
        await service.ensureLoaded();
        await service.addDownloads(
            dramaId: 'a',
            dramaName: '测试剧',
            episodes: [episodes[1]],
            resolveUrl: (_) => gate.future);
      });
      addTearDown(() async {
        service.dispose();
        gate.complete(const DownloadResolveResult(cdnUrl: '', keyHex: ''));
        client.dio.close(force: true);
        await Future<void>.delayed(Duration.zero);
        directory.deleteSync(recursive: true);
      });
      List<Episode>? selection;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          selection = await showPlayerDownloadSheet(
                              context: context,
                              isLandscapeFullScreen: landscape,
                              dramaId: 'a',
                              dramaName: '测试剧',
                              episodes: episodes,
                              currentEpisodeIndex: 0,
                              downloadService: service);
                        },
                        child: const Text('打开下载')),
                  ))));
      await tester.tap(find.text('打开下载'));
      await tester.pumpAndSettle();
      expect(find.text('下载（0 集）'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(find.text('已缓存'), findsOneWidget);
      expect(find.text('下载中'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('episode-0')));
      await tester.tap(find.byKey(const ValueKey('episode-1')));
      await tester.pumpAndSettle();
      expect(find.text('下载（0 集）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('episode-2')));
      await tester.pumpAndSettle();
      expect(find.text('下载（1 集）'), findsOneWidget);
      await tester.tap(find.text('31-35'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('episode-30')));
      await tester.pumpAndSettle();
      expect(find.text('下载（2 集）'), findsOneWidget);
      expect(service.groups['a']!.totalCount, 2); // 确认前没有入队。
      await tester.tap(find.text('下载（2 集）'));
      await tester.pumpAndSettle();
      expect(selection!.map((e) => e.index), [3, 31]);
      await tester.tap(find.text('打开下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('下载（33 集）'), findsOneWidget);
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(find.text('下载（0 集）'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(selection, isNull);
      expect(service.groups['a']!.totalCount, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('普通播放选集仍为单选并立即关闭', (tester) async {
    final current = ValueNotifier<int>(0);
    addTearDown(current.dispose);
    int? selected;
    final episodes = List.generate(
        3, (i) => Episode(index: i + 1, name: '', size: 0, url: 'v$i'));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => showPlayerEpisodeSheet(
                          context: context,
                          isLandscapeFullScreen: false,
                          dramaName: '测试',
                          episodes: episodes,
                          episodeNotifier: current,
                          onSelectEpisode: (i) => selected = i),
                      child: const Text('选集')),
                ))));
    await tester.tap(find.text('选集'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('episode-1')));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(find.byKey(const ValueKey('episode-1')), findsNothing);
  });
}
