import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'services/api_client.dart';
import 'services/app_route_observer.dart';
import 'services/device_profile.dart';
import 'services/download_service.dart';

void main() async {
  // 弹幕表情图片来自 Twemoji，按 CC-BY 4.0 要求注明出处
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Twemoji'], '''
弹幕表情图片：Twemoji
Copyright 2019 Twitter, Inc and other contributors
Copyright 2024 Twemoji contributors (https://github.com/jdecked/twemoji)
Graphics licensed under CC-BY 4.0: https://creativecommons.org/licenses/by/4.0/
''');
  });
  WidgetsFlutterBinding.ensureInitialized();
  await DeviceProfile.init();
  final apiClient = ApiClient();
  runApp(
    ShortPlayApp(
      apiClient: apiClient,
      downloadService: DownloadService(apiClient: apiClient),
    ),
  );
}

class ShortPlayApp extends StatefulWidget {
  const ShortPlayApp({
    super.key,
    required this.apiClient,
    required this.downloadService,
  });

  final ApiClient apiClient;
  final DownloadService downloadService;

  @override
  State<ShortPlayApp> createState() => _ShortPlayAppState();
}

class _ShortPlayAppState extends State<ShortPlayApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // 生命周期回调无法 await，捕获保存错误以免成为未处理的 Future。
      unawaited(widget.downloadService.saveState().catchError((Object error) {
        debugPrint('后台保存缓存失败: $error');
      }));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF2442), // 小红书红
      brightness: Brightness.light,
    ).copyWith(
      primary: const Color(0xFFFF2442),
      secondary: const Color(0xFFFFD93D),
      surface: const Color(0xFFFBFBFB), // 稍微带一点点灰的白，更有质感
    );

    final baseTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: Colors.white,
      // 电视/桌面用方向键操作：加深默认焦点高亮（Tab、底部导航、列表项等）
      focusColor: DeviceProfile.usesFocusUi
          ? const Color(0xFFFF2442).withAlpha(70)
          : null,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.withAlpha(20)),
        ),
        color: Colors.white,
      ),
      textTheme: ThemeData(brightness: Brightness.light).textTheme.apply(
            bodyColor: const Color(0xFF1D1D1F),
            displayColor: const Color(0xFF1D1D1F),
          ),
    );

    return MaterialApp(
      title: 'ShortPlay',
      debugShowCheckedModeBanner: false,
      theme: baseTheme,
      navigatorObservers: [appRouteObserver],
      home: HomePage(
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
      ),
    );
  }
}
