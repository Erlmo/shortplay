import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/device_profile.dart';
import '../tv_side_panel.dart';

import 'player_more_menu.dart';
import 'player_video_surface.dart';

export 'player_more_menu.dart' show PlayerMenuAction;

part 'player_hg_overlay.dart'; // 红果式竖屏控件层
part 'player_hg_landscape.dart'; // 红果式横屏控件层
part 'player_progress_bar.dart'; // 进度条与小按钮

class PlayerControlsOverlay extends StatelessWidget {
  const PlayerControlsOverlay({
    super.key,
    required this.player,
    required this.playerInitialized,
    required this.isLandscapeFullScreen,
    required this.showLandscapeUI,
    required this.isPageTransitioning,
    required this.isOfflinePlayback,
    required this.isTheaterResource,
    required this.danmakuEnabled,
    required this.isSpeedUp,
    required this.userPaused,
    required this.currentEpisodeIndex,
    required this.playbackSpeed,
    required this.positionMsNotifier,
    required this.playingNotifier,
    required this.speedButtonKey,
    required this.seekingPositionMs,
    required this.onBack,
    required this.onToggleDanmaku,
    required this.onSpeedTap,
    this.onSpeedChanged,
    required this.onEpisodeTap,
    required this.onMenuAction,
    required this.onMenuOpened,
    required this.onMenuClosed,
    this.onBottomPanelHeight,
    required this.canDownload,
    required this.sleepTimerActive,
    this.currentQuality = '',
    this.loadQualities,
    this.onQualityChanged,
    this.onSleepDurationChanged,
    this.sleepTimerMinutes,
    required this.onTogglePlay,
    required this.onToggleLandscapeFullScreen,
    required this.onSeekStart,
    required this.onSeekChanged,
    required this.onSeekEnd,
    this.episodeNumber,
    this.durationMsNotifier,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.dramaName = '',
    this.totalEpisodes = 0,
    this.dramaTags = const [],
    this.dramaIntro = '',
    this.onNextEpisode,
    this.isVideoFilled = false,
    this.onToggleVideoFit,
  });

  static const double _seekThumbRadius = 6;
  static const double _portraitSeekTouchHeight = 24;

  final dynamic player;
  final bool playerInitialized;
  final bool isLandscapeFullScreen;
  final bool showLandscapeUI;
  final bool isPageTransitioning;
  final bool isOfflinePlayback;
  final bool isTheaterResource;
  final bool danmakuEnabled;
  final bool isSpeedUp;
  final bool userPaused;
  final int currentEpisodeIndex;
  final int? episodeNumber;
  final double playbackSpeed;
  final ValueNotifier<int> positionMsNotifier;
  final ValueNotifier<bool> playingNotifier;
  final GlobalKey speedButtonKey;
  final double? seekingPositionMs;
  final VoidCallback onBack;
  final VoidCallback onToggleDanmaku;
  final VoidCallback onSpeedTap;
  final ValueChanged<double>? onSpeedChanged;
  final VoidCallback onEpisodeTap;
  final ValueChanged<PlayerMenuAction> onMenuAction;
  final VoidCallback onMenuOpened;
  final VoidCallback onMenuClosed;

  /// 竖屏底部面板（“…”设置面板）的高度；0 表示已关闭。播放页据此缩放画面。
  final ValueChanged<double>? onBottomPanelHeight;
  final bool canDownload;
  final bool sleepTimerActive;
  final String currentQuality;
  final Future<List<String>> Function()? loadQualities;
  final ValueChanged<String>? onQualityChanged;
  final ValueChanged<Duration?>? onSleepDurationChanged;
  final int? sleepTimerMinutes;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleLandscapeFullScreen;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final ValueNotifier<int>? durationMsNotifier;
  final int videoWidth;
  final int videoHeight;
  final String dramaName;
  final int totalEpisodes;
  final List<String> dramaTags;
  final String dramaIntro;

  /// 横屏“下一集”按钮；最后一集时为 null。
  final VoidCallback? onNextEpisode;
  final bool isVideoFilled;
  final VoidCallback? onToggleVideoFit;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final media = MediaQuery.of(context);
    final screenWidth = media.size.width;
    final controlsHorizontalPadding =
        (screenWidth * 0.045).clamp(12.0, 18.0).toDouble();
    final controlsTopPadding =
        (screenWidth * 0.06).clamp(16.0, 24.0).toDouble();
    final controlsBottomPadding =
        (media.viewPadding.bottom + (screenWidth * 0.025).clamp(10.0, 16.0))
            .toDouble();
    final gradientExtraTop = (screenWidth * 0.02).clamp(6.0, 12.0).toDouble();

    // 红果式布局：竖屏手机、手机横屏全屏。电视 / 桌面宽屏走下面的通用布局。
    if (PlayerVideoSurface.usesPhoneLayout(media.size, isLandscapeFullScreen)) {
      return _buildHgPortrait(context, media, textTheme);
    }
    if (isLandscapeFullScreen && !DeviceProfile.isTv) {
      return _buildHgLandscape(context, media);
    }

    return Stack(
      children: [
        if ((!isLandscapeFullScreen && !DeviceProfile.isTv) || showLandscapeUI)
          _TopControls(
            textTheme: textTheme,
            speedButtonKey: speedButtonKey,
            isOfflinePlayback: isOfflinePlayback,
            isTheaterResource: isTheaterResource,
            danmakuEnabled: danmakuEnabled,
            currentEpisodeIndex: currentEpisodeIndex,
            playbackSpeed: playbackSpeed,
            onBack: onBack,
            onToggleDanmaku: onToggleDanmaku,
            onSpeedTap: onSpeedTap,
            onSpeedChanged: onSpeedChanged,
            currentQuality: currentQuality,
            loadQualities: loadQualities,
            onQualityChanged: onQualityChanged,
            onSleepDurationChanged: onSleepDurationChanged,
            sleepTimerMinutes: sleepTimerMinutes,
            onEpisodeTap: onEpisodeTap,
            episodeNumber: episodeNumber,
            canDownload: canDownload,
            sleepTimerActive: sleepTimerActive,
            onMenuAction: onMenuAction,
            onMenuOpened: onMenuOpened,
            onMenuClosed: onMenuClosed,
          ),
        if (isSpeedUp) _SpeedUpHint(textTheme: textTheme),
        if (userPaused) _CenterPlayButton(onTap: onTogglePlay),
        if (_shouldShowLandscapeButton)
          _LandscapeButton(
            videoWidth: videoWidth > 0 ? videoWidth.toDouble() : 1.0,
            videoHeight: videoHeight > 0 ? videoHeight.toDouble() : 1.0,
            media: media,
            textTheme: textTheme,
            onTap: onToggleLandscapeFullScreen,
          ),
        if (((!isLandscapeFullScreen && !DeviceProfile.isTv) ||
                showLandscapeUI) &&
            !isPageTransitioning)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                controlsHorizontalPadding,
                controlsTopPadding + gradientExtraTop,
                controlsHorizontalPadding,
                controlsBottomPadding,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.78),
                    Colors.black.withValues(alpha: 0.25),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (media.orientation == Orientation.landscape &&
                    onToggleVideoFit != null &&
                    playerInitialized)
                  Align(
                    alignment: Alignment.centerRight,
                    child: _videoFitButton,
                  ),
                _PlaybackProgressBar(
                  player: player,
                  positionMsNotifier: positionMsNotifier,
                  playingNotifier: playingNotifier,
                  seekingPositionMs: seekingPositionMs,
                  onTogglePlay: onTogglePlay,
                  onSeekStart: onSeekStart,
                  onSeekChanged: onSeekChanged,
                  onSeekEnd: onSeekEnd,
                  durationMsNotifier: durationMsNotifier,
                ),
              ]),
            ),
          ),
      ],
    );
  }

  bool get _shouldShowLandscapeButton {
    if (!playerInitialized || isLandscapeFullScreen || DeviceProfile.isTv) {
      return false;
    }
    return videoWidth > videoHeight;
  }
}

class _TopControls extends StatelessWidget {
  const _TopControls({
    required this.textTheme,
    required this.speedButtonKey,
    required this.isOfflinePlayback,
    required this.isTheaterResource,
    required this.danmakuEnabled,
    required this.currentEpisodeIndex,
    required this.playbackSpeed,
    required this.onBack,
    required this.onToggleDanmaku,
    required this.onSpeedTap,
    this.onSpeedChanged,
    required this.onEpisodeTap,
    required this.onMenuAction,
    required this.onMenuOpened,
    required this.onMenuClosed,
    required this.canDownload,
    required this.sleepTimerActive,
    this.currentQuality = '',
    this.loadQualities,
    this.onQualityChanged,
    this.onSleepDurationChanged,
    this.sleepTimerMinutes,
    this.episodeNumber,
  });

  final TextTheme textTheme;
  final GlobalKey speedButtonKey;
  final bool isOfflinePlayback;
  final bool isTheaterResource;
  final bool danmakuEnabled;
  final int currentEpisodeIndex;
  final int? episodeNumber;
  final double playbackSpeed;
  final VoidCallback onBack;
  final VoidCallback onToggleDanmaku;
  final VoidCallback onSpeedTap;
  final ValueChanged<double>? onSpeedChanged;
  final VoidCallback onEpisodeTap;
  final ValueChanged<PlayerMenuAction> onMenuAction;
  final VoidCallback onMenuOpened;
  final VoidCallback onMenuClosed;
  final bool canDownload;
  final bool sleepTimerActive;
  final String currentQuality;
  final Future<List<String>> Function()? loadQualities;
  final ValueChanged<String>? onQualityChanged;
  final ValueChanged<Duration?>? onSleepDurationChanged;
  final int? sleepTimerMinutes;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              GestureDetector(
                onTap: onBack,
                child: const _GlassButton(
                  padding: EdgeInsets.all(10),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      GestureDetector(
                        onTap: onEpisodeTap,
                        child: _GlassButton(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          child: Text(
                            '第 ${episodeNumber ?? currentEpisodeIndex + 1} 集',
                            style: textTheme.labelMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PlayerMoreMenu(
                        canDownload: canDownload,
                        isOfflinePlayback: isOfflinePlayback,
                        sleepTimerActive: sleepTimerActive,
                        onOpened: onMenuOpened,
                        onClosed: onMenuClosed,
                        onSelected: onMenuAction,
                        danmakuEnabled: danmakuEnabled,
                        playbackSpeed: playbackSpeed,
                        onToggleDanmaku: onToggleDanmaku,
                        onSpeedChanged: onSpeedChanged,
                        currentQuality: currentQuality,
                        loadQualities: loadQualities,
                        onQualityChanged: onQualityChanged,
                        onSleepDurationChanged: onSleepDurationChanged,
                        sleepTimerMinutes: sleepTimerMinutes,
                        child: const _GlassButton(
                          padding: EdgeInsets.all(10),
                          child: Icon(Icons.more_horiz,
                              color: Colors.white, size: 20),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeedUpHint extends StatelessWidget {
  const _SpeedUpHint({required this.textTheme});

  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 56),
          child: Align(
            alignment: Alignment.topCenter,
            child: _GlassButton(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.fast_forward_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '2.0x 倍速播放',
                    style: textTheme.labelMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CenterPlayButton extends StatelessWidget {
  const _CenterPlayButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.20),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 52,
            ),
          ),
        ),
      ),
    );
  }
}

class _LandscapeButton extends StatelessWidget {
  const _LandscapeButton({
    required this.videoWidth,
    required this.videoHeight,
    required this.media,
    required this.textTheme,
    required this.onTap,
  });

  final double videoWidth;
  final double videoHeight;
  final MediaQueryData media;
  final TextTheme textTheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final videoAspectRatio = videoWidth / videoHeight;
    final displayHeight = media.size.width / videoAspectRatio;
    final videoBottomOffset = (media.size.height - displayHeight) / 2;

    return Positioned(
      left: 0,
      right: 0,
      bottom: videoBottomOffset - 55,
      child: Center(
        child: GestureDetector(
          onTap: onTap,
          child: _GlassButton(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              '全屏显示',
              style: textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
