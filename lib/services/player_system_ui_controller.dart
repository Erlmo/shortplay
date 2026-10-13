import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_profile.dart';
import 'native_ui.dart';

/// 电视不能旋转，请求竖屏会被系统强制转成竖向窗口；电视上一律不锁方向。
Future<void> _setOrientations(List<DeviceOrientation> orientations) async {
  if (DeviceProfile.isTv) return;
  await SystemChrome.setPreferredOrientations(orientations);
}

class PlayerSystemUiController extends ChangeNotifier {
  bool isLandscapeFullScreen = false;
  bool showLandscapeUI = true;

  bool? _isPortraitVideoForSystemUi;
  Timer? _hideUITimer;
  bool _menuOpen = false;

  Future<void> setFullScreen() async {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
    await _setOrientations([DeviceOrientation.portraitUp]);
    await NativeUi.setBottomBarAutoHidden(true);
  }

  /// 回到前台时系统会按上次的 SystemChrome 模式重新显示导航栏，需要再隐藏一次。
  Future<void> reapplyBottomBar() => NativeUi.setBottomBarAutoHidden(true);

  Future<void> updateForVideo(int width, int height) async {
    if (width <= 0 || height <= 0) return;

    final isPortraitVideo = height > width;
    if (_isPortraitVideoForSystemUi == isPortraitVideo) return;
    _isPortraitVideoForSystemUi = isPortraitVideo;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
    await NativeUi.setBottomBarAutoHidden(true);
  }

  Future<void> exitFullScreen() async {
    _isPortraitVideoForSystemUi = null;
    _hideUITimer?.cancel();
    isLandscapeFullScreen = false;
    showLandscapeUI = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await _setOrientations([DeviceOrientation.portraitUp]);
    await NativeUi.setBottomBarAutoHidden(false);
  }

  Future<void> toggleLandscapeFullScreen() async {
    isLandscapeFullScreen = !isLandscapeFullScreen;
    showLandscapeUI = true;
    notifyListeners();

    if (isLandscapeFullScreen) {
      await _setOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await NativeUi.setBottomBarAutoHidden(true);
      _startHideTimer();
    } else {
      _hideUITimer?.cancel();
      await _setOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
      );
      await NativeUi.setBottomBarAutoHidden(true);
    }
  }

  void toggleLandscapeUi() {
    if (!isLandscapeFullScreen || _menuOpen) return;
    if (showLandscapeUI) {
      hideLandscapeUi();
    } else {
      showUIAndResetTimer();
    }
  }

  void hideLandscapeUi() {
    if (!isLandscapeFullScreen) return;
    showLandscapeUI = false;
    _hideUITimer?.cancel();
    notifyListeners();
  }

  void showUIAndResetTimer() {
    if (!isLandscapeFullScreen) return;
    showLandscapeUI = true;
    notifyListeners();
    _startHideTimer();
  }

  void setMenuOpen(bool open) {
    _menuOpen = open;
    if (open) {
      _hideUITimer?.cancel();
      showLandscapeUI = true;
      notifyListeners();
    } else {
      showUIAndResetTimer();
    }
  }

  void _startHideTimer() {
    _hideUITimer?.cancel();
    if (!isLandscapeFullScreen || _menuOpen) return;
    _hideUITimer = Timer(const Duration(seconds: 3), () {
      if (!isLandscapeFullScreen) return;
      showLandscapeUI = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _hideUITimer?.cancel();
    super.dispose();
  }
}
