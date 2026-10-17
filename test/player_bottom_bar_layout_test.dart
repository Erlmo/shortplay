import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/widgets/player/player_controls_overlay.dart';
import 'package:shortplay/widgets/player/player_video_surface.dart';

void main() {
  for (final scenario in [
    (
      name: '安卓手势条',
      platform: TargetPlatform.android,
      inset: 24.0,
      paused: false
    ),
    (
      name: '安卓暂停时',
      platform: TargetPlatform.android,
      inset: 24.0,
      paused: true
    ),
    (
      name: '安卓三键导航',
      platform: TargetPlatform.android,
      inset: 48.0,
      paused: false
    ),
    (
      name: 'iOS Home指示条',
      platform: TargetPlatform.iOS,
      inset: 34.0,
      paused: false
    ),
    (name: 'macOS', platform: TargetPlatform.macOS, inset: 0.0, paused: false),
  ]) {
    testWidgets('${scenario.name}安全区不撑高播放栏，进度条始终贴合画面', (tester) async {
      const screen = Size(480, 960);
      await tester.binding.setSurfaceSize(screen);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final position = ValueNotifier<int>(14000);
      final playing = ValueNotifier<bool>(true);
      final duration = ValueNotifier<int>(123000);
      addTearDown(position.dispose);
      addTearDown(playing.dispose);
      addTearDown(duration.dispose);

      final seekEnds = <double>[];
      final seekChanges = <double>[];
      double? seeking;
      var videoTaps = 0;
      var speedPresses = 0;
      var episodeTaps = 0;
      var pageChanges = 0;

      // 模拟系统条显示/隐藏后仍上报安全区的情况，控件与画面均不应跳动。
      for (final inset in [0.0, scenario.inset, 0.0]) {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: scenario.platform),
          home: MediaQuery(
            data: MediaQueryData(
              size: screen,
              padding: EdgeInsets.only(bottom: inset),
              viewPadding: EdgeInsets.only(bottom: inset),
            ),
            child: StatefulBuilder(builder: (context, setState) {
              return Scaffold(
                body: PageView(
                  scrollDirection: Axis.vertical,
                  onPageChanged: (_) => pageChanges++,
                  children: [
                    Stack(fit: StackFit.expand, children: [
                      const PlayerVideoSurface(
                        textureId: 1,
                        videoWidth: 1080,
                        videoHeight: 1920,
                        isLandscapeFullScreen: false,
                      ),
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => videoTaps++,
                          onLongPress: () => speedPresses++,
                        ),
                      ),
                      PlayerControlsOverlay(
                        player: null,
                        playerInitialized: true,
                        isLandscapeFullScreen: false,
                        showLandscapeUI: true,
                        isPageTransitioning: false,
                        isOfflinePlayback: false,
                        isTheaterResource: true,
                        danmakuEnabled: true,
                        isSpeedUp: false,
                        userPaused: scenario.paused,
                        currentEpisodeIndex: 0,
                        totalEpisodes: 59,
                        playbackSpeed: 1,
                        positionMsNotifier: position,
                        playingNotifier: playing,
                        durationMsNotifier: duration,
                        speedButtonKey: GlobalKey(),
                        seekingPositionMs: seeking,
                        onBack: () {},
                        onToggleDanmaku: () {},
                        onSpeedTap: () {},
                        onEpisodeTap: () => episodeTaps++,
                        onMenuAction: (_) {},
                        onMenuOpened: () {},
                        onMenuClosed: () {},
                        canDownload: true,
                        sleepTimerActive: false,
                        onTogglePlay: () {},
                        onToggleLandscapeFullScreen: () {},
                        onSeekStart: (v) => setState(() => seeking = v),
                        onSeekChanged: (v) {
                          seekChanges.add(v);
                          setState(() => seeking = v);
                        },
                        onSeekEnd: (v) {
                          seekEnds.add(v);
                          position.value = v.toInt();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (context.mounted) setState(() => seeking = null);
                          });
                        },
                      ),
                    ]),
                    const ColoredBox(color: Colors.black),
                  ],
                ),
              );
            }),
          ),
        ));
        expect(tester.takeException(), isNull);
        expect(
            tester.getRect(find.byType(ClipRRect)).bottom, screen.height - 64);
        expect(tester.getCenter(find.byType(Slider)).dy, screen.height - 64);
        expect(tester.getSize(find.byType(Slider)).height, 48);
        expect(tester.getCenter(find.byTooltip('全屏')).dy, screen.height - 32);
      }
      final trackY = screen.height - 64;
      // 起手点偏离细线 20dp、且未准确按中圆点时，仍可拖动进度。
      for (final dy in [-20.0, 20.0]) {
        final count = seekEnds.length;
        final gesture = await tester.startGesture(Offset(100, trackY + dy));
        // 按住寻找圆点的过程中不能触发视频长按倍速。
        await tester.pump(const Duration(milliseconds: 600));
        expect(seekEnds.length, count, reason: '手指尚未松开，不能提前结束拖动');
        await gesture.moveBy(const Offset(80, 6));
        await tester.pump();
        expect(seekEnds.length, count, reason: '时间预览更新后仍应保持同一次拖动');
        await gesture.moveTo(Offset(360, trackY + dy + 6));
        await tester.pump();
        expect(seekEnds.length, count);
        final previewTarget = seekChanges.last;
        expect(seeking, previewTarget);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(seekEnds.length, count + 1);
        expect(seekEnds.last, closeTo(duration.value * 340 / 440, 1));
        expect(seekEnds.last, previewTarget);
        expect(position.value, previewTarget.toInt());
        expect(seeking, isNull);
      }
      expect(videoTaps, 0);
      expect(speedPresses, 0);
      expect(episodeTaps, 0);
      expect(pageChanges, 0);
      // 扩大的触摸区域不盖住选集文字所在的栏中部。
      await tester.tapAt(Offset(90, trackY + 32));
      await tester.pumpAndSettle();
      expect(episodeTaps, 1);
      await tester.tapAt(const Offset(300, 500));
      await tester.pumpAndSettle();
      expect(videoTaps, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
