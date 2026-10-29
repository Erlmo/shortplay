import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/device_profile.dart';
import '../tv_side_panel.dart';
import '../tv_tap.dart';
import 'tv_player_settings_panel.dart';

part 'player_more_classic_sheet.dart'; // 底部弹出的设置面板（电视 / 旧版）
part 'player_more_panel_sheet.dart'; // 红果式深色播放设置面板

enum PlayerMenuAction { download, episodes }

class PlayerMoreMenu extends StatelessWidget {
  const PlayerMoreMenu({
    super.key,
    required this.canDownload,
    required this.isOfflinePlayback,
    required this.sleepTimerActive,
    required this.onOpened,
    required this.onClosed,
    required this.onSelected,
    required this.child,
    this.danmakuEnabled = false,
    this.showDramaFeatures = true,
    this.playbackSpeed = 1,
    this.currentQuality = '',
    this.loadQualities,
    this.onToggleDanmaku,
    this.onSpeedChanged,
    this.onQualityChanged,
    this.onSleepDurationChanged,
    this.sleepTimerMinutes,
  });

  final bool canDownload, isOfflinePlayback, sleepTimerActive, danmakuEnabled;
  final bool showDramaFeatures;
  final double playbackSpeed;
  final String currentQuality;
  final Future<List<String>> Function()? loadQualities;
  final VoidCallback onOpened, onClosed;
  final ValueChanged<PlayerMenuAction> onSelected;
  final Widget child;
  final VoidCallback? onToggleDanmaku;
  final ValueChanged<double>? onSpeedChanged;
  final ValueChanged<String>? onQualityChanged;
  final ValueChanged<Duration?>? onSleepDurationChanged;
  final int? sleepTimerMinutes;

  Future<void> _open(BuildContext context) async {
    onOpened();
    final result = await showPlayerMoreSheet(
      context: context,
      canDownload: canDownload,
      showDramaFeatures: showDramaFeatures,
      isOfflinePlayback: isOfflinePlayback,
      sleepTimerActive: sleepTimerActive,
      danmakuEnabled: danmakuEnabled,
      playbackSpeed: playbackSpeed,
      currentQuality: currentQuality,
      loadQualities: loadQualities,
      onToggleDanmaku: onToggleDanmaku,
      onSpeedChanged: onSpeedChanged,
      onQualityChanged: onQualityChanged,
      onSleepDurationChanged: onSleepDurationChanged,
      sleepTimerMinutes: sleepTimerMinutes,
    );
    onClosed();
    if (result != null) onSelected(result);
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: '更多功能',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(context),
          child: child,
        ),
      );
}

/// 打开“播放设置”（倍速 / 清晰度 / 定时 / 弹幕 / 下载）。
/// 手机上是底部弹层；电视 / 桌面横屏是右侧侧边面板，[showEpisodes] 时
/// 顶部多一个“选集”入口（遥控器没有别的地方能点到选集按钮）。
Future<PlayerMenuAction?> showPlayerMoreSheet({
  required BuildContext context,
  required bool canDownload,
  required bool isOfflinePlayback,
  required bool sleepTimerActive,
  bool danmakuEnabled = false,
  double playbackSpeed = 1,
  String currentQuality = '',
  Future<List<String>> Function()? loadQualities,
  VoidCallback? onToggleDanmaku,
  ValueChanged<double>? onSpeedChanged,
  ValueChanged<String>? onQualityChanged,
  ValueChanged<Duration?>? onSleepDurationChanged,
  int? sleepTimerMinutes,
  bool showEpisodes = false,
  bool showDramaFeatures = true,
  bool forceSidePanel = false,
  ValueChanged<double>? onSheetLayout,
}) {
  // 手机、平板、桌面：红果“更多”面板（竖屏底部弹出；横屏全屏或宽窗口右侧 390dp 侧栏）。
  // 只有电视保留遥控器焦点版的设置面板。
  if (!DeviceProfile.isTv) {
    final size = MediaQuery.of(context).size;
    final side = forceSidePanel || size.width > size.height;
    Widget hg(BuildContext context, bool landscape) => _HgMoreSheet(
          landscape: landscape,
          showDramaFeatures: showDramaFeatures,
          canDownload: canDownload,
          isOfflinePlayback: isOfflinePlayback,
          danmakuEnabled: danmakuEnabled,
          playbackSpeed: playbackSpeed,
          currentQuality: currentQuality,
          loadQualities: loadQualities,
          onToggleDanmaku: onToggleDanmaku,
          onSpeedChanged: onSpeedChanged,
          onQualityChanged: onQualityChanged,
          onSleepDurationChanged: onSleepDurationChanged,
          sleepTimerMinutes: sleepTimerActive ? sleepTimerMinutes : null,
          showEpisodes: showEpisodes,
          onLayout: landscape ? null : onSheetLayout,
          onSelected: (value) => Navigator.of(context).pop(value),
        );
    if (side) {
      return showGeneralDialog<PlayerMenuAction>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭',
        barrierColor: Colors.black.withAlpha(40),
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, __) {
          final size = MediaQuery.of(context).size;
          return Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: math.min(size.width, 390),
              height: size.height,
              child: hg(context, true),
            ),
          );
        },
        transitionBuilder: (context, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );
    }
    return showModalBottomSheet<PlayerMenuAction>(
      context: context,
      backgroundColor: Colors.transparent,
      // 画面缩到面板上方，遮罩透明
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: false,
      builder: (context) => hg(context, false),
    );
  }
  final side = forceSidePanel || useSidePanel(context);
  Widget sheet(BuildContext context) => _PlayerMoreSheet(
        canDownload: canDownload,
        isOfflinePlayback: isOfflinePlayback,
        sleepTimerActive: sleepTimerActive,
        danmakuEnabled: danmakuEnabled,
        playbackSpeed: playbackSpeed,
        currentQuality: currentQuality,
        loadQualities: loadQualities,
        onToggleDanmaku: onToggleDanmaku,
        onSpeedChanged: onSpeedChanged,
        onQualityChanged: onQualityChanged,
        onSleepDurationChanged: onSleepDurationChanged,
        sleepTimerMinutes: sleepTimerMinutes,
        showEpisodes: showEpisodes,
        sidePanel: side,
        onSelected: (value) => Navigator.of(context).pop(value),
      );
  if (side) {
    return showSidePanel<PlayerMenuAction>(
      context: context,
      widthFraction: 0.36,
      minWidth: 420,
      color: panelBackground,
      // 遮罩很淡：调倍速 / 清晰度时能直接看到画面变化
      barrierColor: Colors.black.withAlpha(40),
      builder: (context) => TvPlayerSettingsPanel(
        canDownload: canDownload,
        isOfflinePlayback: isOfflinePlayback,
        danmakuEnabled: danmakuEnabled,
        playbackSpeed: playbackSpeed,
        currentQuality: currentQuality,
        loadQualities: loadQualities,
        onToggleDanmaku: onToggleDanmaku,
        onSpeedChanged: onSpeedChanged,
        onQualityChanged: onQualityChanged,
        onSleepDurationChanged: onSleepDurationChanged,
        sleepTimerMinutes: sleepTimerActive ? sleepTimerMinutes : null,
        showEpisodes: showEpisodes,
        onSelected: (value) => Navigator.of(context).pop(value),
      ),
    );
  }
  return showModalBottomSheet<PlayerMenuAction>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.48),
    isScrollControlled: true,
    useSafeArea: true,
    builder: sheet,
  );
}
