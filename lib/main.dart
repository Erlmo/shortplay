import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'services/api_client.dart';
import 'services/app_route_observer.dart';
import 'services/download_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      widget.downloadService.saveState();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme =
        ColorScheme.fromSeed(
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
