import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/main.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/services/download_service.dart';
import 'package:shortplay/services/player_system_ui_controller.dart';
import 'package:shortplay/widgets/player/player_controls_overlay.dart';

import 'support/no_app_updates.dart';

class _FocusApiClient extends ApiClient {
  _FocusApiClient({this.manyNewPlays = false});

  final bool manyNewPlays;
  @override
  Future<List<String>> fetchNotice() async => [];

  @override
  Future<HomePageResult> fetchHomePage(
          {int? offset, String? sessionId}) async =>
      HomePageResult(
        offset: 0,
        sessionId: '',
        count: 1,
        hasMore: false,
        nextOffset: 0,
        list: [
          Drama.fromJson({'id': 1, 'name': '首页列表短剧'})
        ],
      );

  @override
  Future<NewPlayResult> fetchNewPlay({
    int? offset,
    String? sessionId,
    String? cellGender,
  }) async =>
      NewPlayResult(
        offset: 0,
        sessionId: '',
        count: 1,
        hasMore: false,
        nextOffset: 0,
        list: [
          if (manyNewPlays)
            ...List.generate(
                100,
                (index) => Drama.fromJson({
                      'id': index + 2,
                      'name': '新剧列表短剧 $index',
                    }))
          else
            Drama.fromJson({'id': 2, 'name': '新剧列表短剧'})
        ],
      );
}

void main() {
  setUp(() {
    DeviceProfile.isTv = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      SystemChannels.platform,
      const MethodChannel('shortplay/native_player'),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
  });

  tearDown(() {
    DeviceProfile.isTv = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      SystemChannels.platform,
      const MethodChannel('shortplay/native_player'),
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('电视顶部标签用方向键移动时显示焦点高亮', (tester) async {
    final client = ApiClient();
    final downloads = DownloadService(apiClient: client);
    addTearDown(downloads.dispose);
    addTearDown(() => client.dio.close(force: true));
    await tester.pumpWidget(ShortPlayApp(
        apiClient: client,
        downloadService: downloads,
        appUpdateService: NoAppUpdates(client)));
    await tester.pump(const Duration(seconds: 1));
    final tabContext = tester.element(find.text('首页').first);
    Focus.of(tabContext).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(Focus.of(tester.element(find.text('新剧'))).hasFocus, isTrue);
    expect(Focus.of(tabContext).hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 400));
    expect(Focus.of(tester.element(find.text('新剧'))).hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('切换栏目后遥控器只聚焦可见列表，底部切页后也不能聚焦隐藏内容', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = _FocusApiClient();
    final downloads = DownloadService(apiClient: client);
    addTearDown(downloads.dispose);
    addTearDown(() => client.dio.close(force: true));
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ShortPlayApp(
        apiClient: client,
        downloadService: downloads,
        appUpdateService: NoAppUpdates(client)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final homeFocus = Focus.of(tester.element(find.text('首页列表短剧')));
    homeFocus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(homeFocus.hasFocus, isTrue);

    await tester.tap(find.text('新剧'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    homeFocus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(homeFocus.hasFocus, isFalse);
    final newTabFocus = Focus.of(tester.element(find.text('新剧')));
    newTabFocus.requestFocus();
    await tester.pump();
    final newFocus = Focus.of(tester.element(find.text('新剧列表短剧')));
    newFocus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(newFocus.hasFocus, isTrue);

    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    newFocus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(newFocus.hasFocus, isFalse);
    newTabFocus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(newTabFocus.hasFocus, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('电视浏览新剧多行后返回聚焦当前栏目，保留位置并可左右切换及再次返回退出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var exits = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
    final client = _FocusApiClient(manyNewPlays: true);
    final downloads = DownloadService(apiClient: client);
    addTearDown(downloads.dispose);
    addTearDown(() => client.dio.close(force: true));
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ShortPlayApp(
        apiClient: client,
        downloadService: downloads,
        appUpdateService: NoAppUpdates(client)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('新剧'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final cardContext = tester.element(find.text('新剧列表短剧 0'));
    final position = Scrollable.of(cardContext).position;
    Focus.of(cardContext).requestFocus();
    await tester.pump();
    for (var row = 0; row < 6; row++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(position.pixels, greaterThan(0));
    final offset = position.pixels;
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(exits, 0);
    expect(Focus.of(tester.element(find.text('新剧'))).hasFocus, isTrue);
    expect(position.pixels, offset);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(Focus.of(tester.element(find.text('推荐'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(Focus.of(tester.element(find.text('热播'))).hasFocus, isTrue);
    await tester.binding.handlePopRoute();
    expect(exits, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('手机首页返回键仍按系统行为退出', (tester) async {
    DeviceProfile.isTv = false;
    SharedPreferences.setMockInitialValues({});
    var exits = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
    final client = _FocusApiClient();
    final downloads = DownloadService(apiClient: client);
    addTearDown(downloads.dispose);
    addTearDown(() => client.dio.close(force: true));
    await tester.pumpWidget(ShortPlayApp(
        apiClient: client,
        downloadService: downloads,
        appUpdateService: NoAppUpdates(client)));
    await tester.pump();
    await tester.binding.handlePopRoute();
    expect(exits, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('电视未切换横屏时集数和进度一起自动隐藏并可重新显示', (tester) async {
    final controller = PlayerSystemUiController();
    final position = ValueNotifier<int>(10000);
    final duration = ValueNotifier<int>(60000);
    final playing = ValueNotifier<bool>(true);
    addTearDown(controller.dispose);
    addTearDown(position.dispose);
    addTearDown(duration.dispose);
    addTearDown(playing.dispose);
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => PlayerControlsOverlay(
            player: null,
            playerInitialized: true,
            isLandscapeFullScreen: false,
            showLandscapeUI: controller.showLandscapeUI,
            isPageTransitioning: false,
            isOfflinePlayback: true,
            isTheaterResource: true,
            danmakuEnabled: false,
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
            onEpisodeTap: () {},
            onMenuAction: (_) {},
            onMenuOpened: () => controller.setMenuOpen(true),
            onMenuClosed: () => controller.setMenuOpen(false),
            canDownload: false,
            sleepTimerActive: false,
            onTogglePlay: () {},
            onToggleLandscapeFullScreen: () {},
            onSeekStart: (_) {},
            onSeekChanged: (_) {},
            onSeekEnd: (_) {},
          ),
        ),
      ),
    ));
    await controller.setFullScreen();
    expect(find.text('第 1 集'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('第 1 集'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    controller.toggleLandscapeUi();
    await tester.pump();
    expect(find.text('第 1 集'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    controller.hideLandscapeUi();
    await tester.pump();
    expect(find.text('第 1 集'), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('电视系统返回键先关闭屏显，再退出播放页', (tester) async {
    final client = ApiClient();
    addTearDown(() => client.dio.close(force: true));
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('播放前页面')),
    ));
    navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        drama: Drama.fromJson({'id': 1, 'name': '电视测试'}),
        apiClient: client,
        offlineEpisodes: const [],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(PlayerPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.text('播放前页面'), findsOneWidget);
  });
}
