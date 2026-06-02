import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_ui.dart';

class PlayerSystemUiController extends ChangeNotifier {
  bool isLandscapeFullScreen = false;
  bool showLandscapeUI = true;

  bool? _isPortraitVideoForSystemUi;
  Timer? _hideUITimer;

  Future<void> setFullScreen() async {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

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
  }

  Future<void> exitFullScreen() async {
    _isPortraitVideoForSystemUi = null;
    _hideUITimer?.cancel();
    isLandscapeFullScreen = false;
    showLandscapeUI = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await NativeUi.setHomeIndicatorHidden(false);
  }

  Future<void> toggleLandscapeFullScreen() async {
    isLandscapeFullScreen = !isLandscapeFullScreen;
    showLandscapeUI = true;
    notifyListeners();

    if (isLandscapeFullScreen) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await NativeUi.setHomeIndicatorHidden(false);
      _startHideTimer();
    } else {
      _hideUITimer?.cancel();
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await NativeUi.setHomeIndicatorHidden(false);
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
      );
    }
  }

  void hideLandscapeUi() {
    if (!isLandscapeFullScreen) return;
    showLandscapeUI = false;
    _hideUITimer?.cancel();
    NativeUi.setHomeIndicatorHidden(true);
    notifyListeners();
  }

  void showUIAndResetTimer() {
    if (!isLandscapeFullScreen) return;
    showLandscapeUI = true;
    NativeUi.setHomeIndicatorHidden(false);
    notifyListeners();
    _startHideTimer();
  }

  void _startHideTimer() {
    _hideUITimer?.cancel();
    if (!isLandscapeFullScreen) return;
    _hideUITimer = Timer(const Duration(seconds: 3), () {
      if (!isLandscapeFullScreen) return;
      showLandscapeUI = false;
      NativeUi.setHomeIndicatorHidden(true);
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _hideUITimer?.cancel();
    super.dispose();
  }
}
