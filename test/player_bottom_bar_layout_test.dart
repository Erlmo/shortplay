import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/widgets/player/player_controls_overlay.dart';
import 'package:shortplay/widgets/player/player_video_surface.dart';

void main() {
  for (final scenario in [
    (name: '安卓手势条', platform: TargetPlatform.android, inset: 24.0),
    (name: '安卓三键导航', platform: TargetPlatform.android, inset: 48.0),
    (name: 'iOS Home指示条', platform: TargetPlatform.iOS, inset: 34.0),
    (name: 'macOS', platform: TargetPlatform.macOS, inset: 0.0),
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
            child: Scaffold(
              body: Stack(fit: StackFit.expand, children: [
                const PlayerVideoSurface(
                  textureId: 1,
                  videoWidth: 1080,
                  videoHeight: 1920,
                  isLandscapeFullScreen: false,
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
                  userPaused: false,
                  currentEpisodeIndex: 0,
                  totalEpisodes: 59,
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
                  onMenuAction: (_) {},
                  onMenuOpened: () {},
                  onMenuClosed: () {},
                  canDownload: true,
                  sleepTimerActive: false,
                  onTogglePlay: () {},
                  onToggleLandscapeFullScreen: () {},
                  onSeekStart: (_) {},
                  onSeekChanged: (_) {},
                  onSeekEnd: (_) {},
                ),
              ]),
            ),
          ),
        ));
        expect(tester.takeException(), isNull);
        expect(
            tester.getRect(find.byType(ClipRRect)).bottom, screen.height - 56);
        expect(tester.getCenter(find.byType(Slider)).dy, screen.height - 56);
        expect(tester.getCenter(find.byTooltip('全屏')).dy, screen.height - 28);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
