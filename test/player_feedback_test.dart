import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/widgets/app_notice.dart';
import 'package:shortplay/widgets/player/player_more_menu.dart';
import 'package:shortplay/widgets/player/sleep_timer_sheet.dart';

const _output = String.fromEnvironment('PLAYER_UI_PREVIEW');
const _font = String.fromEnvironment('PLAYER_UI_PREVIEW_FONT');
const _icons = String.fromEnvironment('PLAYER_UI_PREVIEW_ICONS');

Future<void> _capture(
    WidgetTester tester, GlobalKey boundaryKey, String name) async {
  if (_output.isEmpty) return;
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory(_output)..createSync(recursive: true);
    File('${directory.path}/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _app(GlobalKey key, WidgetBuilder builder, {double scale = 1}) {
  return RepaintBoundary(
      key: key,
      child: MaterialApp(
        theme: ThemeData(
            useMaterial3: true,
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xFFFF2442)),
            fontFamily: _font.isEmpty ? null : 'PreviewSans'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(builder: builder),
      ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // 可选输出实际组件预览；日常测试不依赖本机字体或截图目录。
    for (final (name, path) in [
      ('PreviewSans', _font),
      ('MaterialIcons', _icons)
    ]) {
      if (path.isEmpty) continue;
      final loader = FontLoader(name)
        ..addFont(File(path).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  test('清晰度来自两种 JSON 格式，去重排序并过滤无地址项', () {
    final items = [
      FqVideoItem.fromJson({
        'main_url': 'https://example.com/a',
        'video_meta': {'definition': '1080p'}
      }),
      FqVideoItem.fromJson(
          {'main_url': 'https://example.com/b', 'definition': '720p'}),
      FqVideoItem.fromJson(
          {'main_url': 'https://example.com/c', 'definition': '720P'}),
      FqVideoItem.fromJson({'main_url': '', 'definition': '480p'}),
      FqVideoItem.fromJson(
          {'main_url': 'https://example.com/d', 'definition': ''}),
    ];
    expect(TheaterVideoPreloadManager.definitionsFor(items), ['720p', '1080p']);
    expect(TheaterVideoPreloadManager.definitionsFor([]), isEmpty);
  });

  testWidgets('面板仅显示接口清晰度，点击生效且图标对齐', (tester) async {
    String? quality;
    await tester.pumpWidget(_app(
        GlobalKey(),
        (context) => Scaffold(
                body: PlayerMoreMenu(
              canDownload: true,
              isOfflinePlayback: false,
              sleepTimerActive: false,
              currentQuality: '720p',
              loadQualities: () async => ['720p', '1080p'],
              onQualityChanged: (value) => quality = value,
              onOpened: () {},
              onClosed: () {},
              onSelected: (_) {},
              child: const Icon(Icons.more_horiz),
            ))));
    await tester.tap(find.byTooltip('更多功能'));
    await tester.pumpAndSettle();
    expect(find.text('720P'), findsOneWidget);
    expect(find.text('1080P'), findsOneWidget);
    expect(find.text('360P'), findsNothing);
    await tester.tap(find.text('1080P'));
    await tester.pumpAndSettle();
    expect(quality, '1080p');
    expect(tester.widget<Text>(find.text('1080P')).style!.fontWeight,
        FontWeight.w700);
    final icons = [
      CupertinoIcons.speedometer,
      CupertinoIcons.tv,
      CupertinoIcons.chat_bubble_text,
      CupertinoIcons.arrow_down_to_line,
      CupertinoIcons.timer
    ];
    final left = tester.getRect(find.byIcon(icons.first)).left;
    for (final icon in icons) {
      expect(tester.getRect(find.byIcon(icon)).left, left);
    }
    expect(tester.takeException(), isNull);
  });

  for (final screen in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('更多菜单 ${screen.width} 宽、大字号下保持可操作和离线禁选', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = screen;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      PlayerMenuAction? action;
      int closed = 0;
      Duration? timer;
      double? speed;
      int toggles = 0;
      await tester.pumpWidget(_app(
          boundary,
          (context) => Scaffold(
                backgroundColor: const Color(0xFF111114),
                body: SafeArea(
                    child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: PlayerMoreMenu(
                        canDownload: false,
                        isOfflinePlayback: true,
                        sleepTimerActive: true,
                        sleepTimerMinutes: 60,
                        onSleepDurationChanged: (value) => timer = value,
                        onSpeedChanged: (value) => speed = value,
                        onToggleDanmaku: () => toggles++,
                        onOpened: () {},
                        onClosed: () => closed++,
                        onSelected: (value) => action = value,
                        child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(Icons.more_horiz, color: Colors.white)),
                      )),
                )),
              ),
          scale: 1.4));
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();
      expect(speed, 1.5);
      expect(tester.widget<Text>(find.text('1.5x')).style!.fontWeight,
          FontWeight.w700);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(toggles, 1);
      await tester.tap(find.text('已下载本地'));
      await tester.pumpAndSettle();
      expect(action, isNull);
      expect(find.text('定时'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, 'menu-${screen.width.toInt()}');
      await tester.ensureVisible(find.text('30分'));
      await tester.tap(find.text('30分'));
      await tester.pumpAndSettle();
      expect(timer, const Duration(minutes: 30));
      expect(find.text('播放设置'), findsOneWidget);
      expect(tester.widget<Text>(find.text('30分')).style!.fontWeight,
          FontWeight.w700);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(timer, Duration.zero);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(closed, 1);
    });
  }

  for (final screen in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('定时面板 ${screen.width} 宽展示六项选项并支持取消', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = screen;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      Duration? selected;
      await tester.pumpWidget(_app(
          boundary,
          (context) => Scaffold(
                backgroundColor: const Color(0xFF111114),
                body: Center(
                    child: TextButton(
                        onPressed: () async {
                          selected = await showSleepTimerSheet(
                              context: context,
                              remaining: const Duration(minutes: 25),
                              isActive: true);
                        },
                        child: const Text('设置定时'))),
              ),
          scale: 1.2));
      await tester.tap(find.text('设置定时'));
      await tester.pumpAndSettle();
      expect(find.text('15 分钟'), findsOneWidget);
      expect(find.text('120 分钟'), findsOneWidget);
      expect(find.text('取消定时'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, 'timer-${screen.width.toInt()}');
      await tester.ensureVisible(find.text('取消定时'));
      await tester.tap(find.text('取消定时'));
      await tester.pumpAndSettle();
      expect(selected, Duration.zero);
    });
  }

  for (final screen in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('浮动提示 ${screen.width} 宽不遮挡底部控件，新消息替换旧消息', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = screen;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      late BuildContext pageContext;
      await tester.pumpWidget(_app(boundary, (context) {
        pageContext = context;
        return const Scaffold(
            backgroundColor: Color(0xFF111114), body: SizedBox.expand());
      }, scale: 1.4));
      showAppNotice(pageContext,
          message: '缓存任务已添加',
          detail: '已加入 12 集，可在缓存页查看进度',
          kind: AppNoticeKind.success,
          abovePlayerControls: true);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tester.getRect(find.byType(AppNoticeCard)).bottom,
          lessThanOrEqualTo(screen.height - 72));
      expect(tester.getRect(find.byType(AppNoticeCard)).width,
          lessThanOrEqualTo(440));
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary, 'notice-${screen.width.toInt()}');
      showAppNotice(pageContext,
          message: '操作未完成',
          detail: '网络连接暂时不可用，请检查网络后重试',
          kind: AppNoticeKind.error,
          abovePlayerControls: true);
      await tester.pumpAndSettle();
      expect(find.text('缓存任务已添加'), findsNothing);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.byType(AppNoticeCard), findsOneWidget);
      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      expect(find.byType(AppNoticeCard), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
