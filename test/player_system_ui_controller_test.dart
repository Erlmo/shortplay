import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/player_system_ui_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            SystemChannels.platform, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('横屏点击依次隐藏和显示播放控件', (tester) async {
    final controller = PlayerSystemUiController();
    addTearDown(controller.dispose);
    await controller.toggleLandscapeFullScreen();
    expect(controller.showLandscapeUI, isTrue);

    final visibilityChanges = <bool>[];
    controller.addListener(() {
      visibilityChanges.add(controller.showLandscapeUI);
    });

    controller.toggleLandscapeUi();
    expect(controller.showLandscapeUI, isFalse);
    await tester.pump(const Duration(seconds: 4));
    expect(visibilityChanges, [false]);

    controller.toggleLandscapeUi();
    expect(controller.showLandscapeUI, isTrue);
    expect(visibilityChanges, [false, true]);
    await tester.pump(const Duration(seconds: 3));
    expect(visibilityChanges, [false, true, false]);
  });

  testWidgets('横屏重新显示控件后完整三秒才隐藏，旧计时不会提前触发', (tester) async {
    final controller = PlayerSystemUiController();
    addTearDown(controller.dispose);
    await controller.toggleLandscapeFullScreen();
    await tester.pump(const Duration(seconds: 2));

    controller.toggleLandscapeUi();
    await tester.pump(const Duration(milliseconds: 500));
    controller.toggleLandscapeUi();
    expect(controller.showLandscapeUI, isTrue);

    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.showLandscapeUI, isTrue);
    await tester.pump(const Duration(milliseconds: 2499));
    expect(controller.showLandscapeUI, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.showLandscapeUI, isFalse);
  });

  testWidgets('竖屏不切换横屏控件状态', (tester) async {
    final controller = PlayerSystemUiController();
    addTearDown(controller.dispose);
    int notifications = 0;
    controller.addListener(() => notifications++);

    controller.toggleLandscapeUi();
    await tester.pump(const Duration(seconds: 4));

    expect(controller.isLandscapeFullScreen, isFalse);
    expect(controller.showLandscapeUI, isTrue);
    expect(notifications, 0);
  });

  testWidgets('菜单打开期间点击不隐藏控件，关闭菜单后三秒自动隐藏', (tester) async {
    final controller = PlayerSystemUiController();
    addTearDown(controller.dispose);
    await controller.toggleLandscapeFullScreen();
    await tester.pump(const Duration(seconds: 2));

    controller.setMenuOpen(true);
    controller.toggleLandscapeUi();
    expect(controller.showLandscapeUI, isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(controller.showLandscapeUI, isTrue);

    controller.setMenuOpen(false);
    await tester.pump(const Duration(milliseconds: 2999));
    expect(controller.showLandscapeUI, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.showLandscapeUI, isFalse);
  });

  testWidgets('退出横屏取消自动隐藏并恢复控件显示', (tester) async {
    final controller = PlayerSystemUiController();
    addTearDown(controller.dispose);
    await controller.toggleLandscapeFullScreen();
    await tester.pump(const Duration(seconds: 2));
    await controller.toggleLandscapeFullScreen();
    await tester.pump(const Duration(seconds: 4));

    expect(controller.isLandscapeFullScreen, isFalse);
    expect(controller.showLandscapeUI, isTrue);
  });

  testWidgets('销毁播放器后取消控件自动隐藏计时', (tester) async {
    final controller = PlayerSystemUiController();
    await controller.toggleLandscapeFullScreen();
    controller.dispose();
    await tester.pump(const Duration(seconds: 4));

    expect(controller.showLandscapeUI, isTrue);
    expect(tester.takeException(), isNull);
  });
}
