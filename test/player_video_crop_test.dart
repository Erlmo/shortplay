import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/widgets/player/player_controls_overlay.dart';
import 'package:shortplay/widgets/player/player_video_surface.dart';

void main() {
  test('横向裁掉恰好15%仍铺满，超过15%才完整显示', () {
    // 片源1:2，画面区域高200：铺满后100×200，左右合计裁15/100。
    expect(PlayerVideoSurface.phoneVideoRect(const Size(85, 264), 100, 200),
        rectMoreOrLessEquals(const Rect.fromLTWH(-7.5, 0, 100, 200)));
    expect(PlayerVideoSurface.phoneVideoRect(const Size(86, 264), 100, 200),
        rectMoreOrLessEquals(const Rect.fromLTWH(-7, 0, 100, 200)));
    // 宽度再减1，裁16/100，回退按宽，黑边均分到画面区域上下。
    expect(PlayerVideoSurface.phoneVideoRect(const Size(84, 264), 100, 200),
        rectMoreOrLessEquals(const Rect.fromLTWH(0, 16, 84, 168)));
  });

  test('纵向裁切也使用整轴15%阈值', () {
    expect(PlayerVideoSurface.phoneVideoRect(const Size(50, 149), 100, 200),
        rectMoreOrLessEquals(const Rect.fromLTWH(0, -7.5, 50, 100)));
    expect(PlayerVideoSurface.phoneVideoRect(const Size(50, 148), 100, 200),
        rectMoreOrLessEquals(const Rect.fromLTWH(4, 0, 42, 84)));
  });

  testWidgets('细长手机完整显示视频，底栏与进度条仍固定在画面区域底边', (tester) async {
    const screen = Size(480, 1200);
    await tester.binding.setSurfaceSize(screen);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PlayerVideoSurface(
          textureId: 1,
          videoWidth: 1080,
          videoHeight: 1920,
          isLandscapeFullScreen: false,
          fillScreen: true, // 从横屏切回竖屏时仍应遵守15%阈值。
        ),
      ),
    ));
    final rect = tester.getRect(find.byType(Texture));
    expect(rect.width, closeTo(480, 0.001));
    expect(rect.height, closeTo(480 * 16 / 9, 0.001));
    expect(rect.center.dy, (1200 - 64) / 2);
    expect(tester.getRect(find.byType(ClipRRect)).bottom, 1200 - 64);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏完整显示与铺满屏幕切换保持比例，按钮调用切换回调', (tester) async {
    const screen = Size(844, 390);
    await tester.binding.setSurfaceSize(screen);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final position = ValueNotifier<int>(0);
    final playing = ValueNotifier<bool>(true);
    final duration = ValueNotifier<int>(120000);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);
    addTearDown(duration.dispose);
    var filled = false;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        return Scaffold(
          body: Stack(fit: StackFit.expand, children: [
            PlayerVideoSurface(
              textureId: 1,
              videoWidth: 1920,
              videoHeight: 1080,
              isLandscapeFullScreen: true,
              fillScreen: filled,
            ),
            PlayerControlsOverlay(
              player: null,
              playerInitialized: true,
              isLandscapeFullScreen: true,
              isVideoFilled: filled,
              onToggleVideoFit: () => setState(() => filled = !filled),
              showLandscapeUI: true,
              isPageTransitioning: false,
              isOfflinePlayback: false,
              isTheaterResource: true,
              danmakuEnabled: true,
              isSpeedUp: false,
              userPaused: false,
              currentEpisodeIndex: 0,
              playbackSpeed: 1,
              positionMsNotifier: position,
              playingNotifier: playing,
              durationMsNotifier: duration,
              speedButtonKey: GlobalKey(),
              seekingPositionMs: null,
              onBack: () {},
              onToggleDanmaku: () {},
              onSpeedTap: () {},
              onSpeedChanged: (_) {},
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
        );
      }),
    ));
    var rect = tester.getRect(find.byType(Texture));
    expect(rect.height, closeTo(390, 0.001));
    expect(rect.width, lessThan(844));
    final fitButton = find.byTooltip('铺满屏幕（等比例裁切）');
    expect(tester.getCenter(fitButton).dy,
        closeTo(tester.getCenter(find.text('倍速')).dy, 0.001));
    expect(tester.getCenter(fitButton).dx,
        greaterThan(tester.getCenter(find.text('倍速')).dx));
    expect(find.byIcon(Icons.crop_free_rounded), findsOneWidget);
    await tester.tap(fitButton);
    await tester.pump();
    rect = tester.getRect(find.byType(Texture));
    expect(filled, isTrue);
    expect(rect.width, closeTo(844, 0.001));
    expect(rect.height, greaterThan(390));
    expect(rect.width / rect.height, closeTo(16 / 9, 0.001));
    expect(rect.center, const Offset(422, 195));
    expect(find.byIcon(Icons.fit_screen_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('切换为完整显示'));
    await tester.pump();
    expect(filled, isFalse);
    expect(tester.getRect(find.byType(Texture)).height, closeTo(390, 0.001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
