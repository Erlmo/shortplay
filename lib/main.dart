import 'dart:async';

import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'services/api_client.dart';
import 'services/app_route_observer.dart';
import 'services/app_update_service.dart';
import 'services/device_profile.dart';
import 'services/download_service.dart';
import 'widgets/app_update_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DeviceProfile.init();
  final apiClient = ApiClient();
  runApp(
    ShortPlayApp(
      apiClient: apiClient,
      downloadService: DownloadService(apiClient: apiClient),
    ),
  );
  // 不阻塞界面启动；注册失败先用默认设备取数据，后台继续重试。
  unawaited(apiClient.initializeDevice().catchError((Object error) {
    debugPrint('设备初始化失败，可重试加载');
  }));
}

class ShortPlayApp extends StatefulWidget {
  const ShortPlayApp({
    super.key,
    required this.apiClient,
    required this.downloadService,
    this.appUpdateService,
  });

  final ApiClient apiClient;
  final DownloadService downloadService;
  final AppUpdateService? appUpdateService;

  @override
  State<ShortPlayApp> createState() => _ShortPlayAppState();
}

class _ShortPlayAppState extends State<ShortPlayApp>
    with WidgetsBindingObserver {
  late final AppUpdateService _updates =
      widget.appUpdateService ?? AppUpdateService(apiClient: widget.apiClient);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.appUpdateService == null) _updates.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.apiClient.retryDeviceRegistration());
      unawaited(widget.apiClient.playbackReports.flush(force: true));
    }
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
      // 保留默认控件的方向键反馈，电视使用更柔和的底色。
      focusColor: DeviceProfile.usesFocusUi
          ? const Color(0xFFFF2442).withAlpha(DeviceProfile.isTv ? 28 : 70)
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
      builder: (_, child) => AppUpdateGate(
        service: _updates,
        child: child ?? const SizedBox.shrink(),
      ),
      home: HomePage(
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
        appUpdateService: _updates,
      ),
    );
  }
}
