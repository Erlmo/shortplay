import 'package:flutter/material.dart';

import 'player_more_menu.dart';

export 'player_more_menu.dart' show PlayerMenuAction;

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
  });

  static const double _seekThumbRadius = 6;

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

    return Stack(
      children: [
        if (!isLandscapeFullScreen || showLandscapeUI)
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
        if ((!isLandscapeFullScreen || showLandscapeUI) && !isPageTransitioning)
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
              child: _PlaybackProgressBar(
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
            ),
          ),
      ],
    );
  }

  bool get _shouldShowLandscapeButton {
    if (!playerInitialized || isLandscapeFullScreen) {
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

class _PlaybackProgressBar extends StatefulWidget {
  const _PlaybackProgressBar({
    required this.player,
    required this.positionMsNotifier,
    required this.playingNotifier,
    required this.seekingPositionMs,
    required this.onTogglePlay,
    required this.onSeekStart,
    required this.onSeekChanged,
    required this.onSeekEnd,
    this.durationMsNotifier,
  });

  final dynamic player;
  final ValueNotifier<int> positionMsNotifier;
  final ValueNotifier<bool> playingNotifier;
  final double? seekingPositionMs;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final ValueNotifier<int>? durationMsNotifier;

  @override
  State<_PlaybackProgressBar> createState() => _PlaybackProgressBarState();
}

class _PlaybackProgressBarState extends State<_PlaybackProgressBar> {
  bool _dragging = false;
  double _dragValue = 0;
  double? _seekTarget;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.positionMsNotifier,
        widget.playingNotifier,
        if (widget.durationMsNotifier != null) widget.durationMsNotifier!,
      ]),
      builder: (context, _) {
        final durationMs = widget.durationMsNotifier?.value ??
            widget.player?.state.duration.inMilliseconds ??
            0;

        // seek 保护：松手后保持显示 seek 目标，直到 position 追上来
        if (_seekTarget != null) {
          final pos = widget.positionMsNotifier.value.toDouble();
          if ((pos - _seekTarget!).abs() < 1000) {
            _seekTarget = null;
          }
        }

        final displayPositionMs = _dragging
            ? _dragValue
            : (_seekTarget ?? widget.positionMsNotifier.value.toDouble());

        return Row(
          children: [
            GestureDetector(
              onTap: widget.onTogglePlay,
              child: Icon(
                widget.playingNotifier.value
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSlider(context, durationMs, displayPositionMs),
            ),
            const SizedBox(width: 12),
            Text(
              '${_fmt(Duration(milliseconds: displayPositionMs.toInt()))} / '
              '${_fmt(Duration(milliseconds: durationMs))}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontFamily: 'monospace',
                  ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSlider(BuildContext ctx, int durationMs, double posMs) {
    final max = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final value = posMs.clamp(0.0, max);

    return SliderTheme(
      data: SliderTheme.of(ctx).copyWith(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: PlayerControlsOverlay._seekThumbRadius,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: Colors.white.withValues(alpha: 0.92),
        inactiveTrackColor: Colors.white.withValues(alpha: 0.20),
        thumbColor: Colors.white,
        overlayColor: Colors.white.withValues(alpha: 0.12),
      ),
      child: Slider(
        min: 0,
        max: max,
        value: value,
        onChangeStart: durationMs <= 0
            ? null
            : (v) {
                setState(() {
                  _dragging = true;
                  _dragValue = v;
                  _seekTarget = null;
                });
                widget.onSeekStart(v);
              },
        onChanged: durationMs <= 0
            ? null
            : (v) {
                setState(() => _dragValue = v);
                widget.onSeekChanged(v);
              },
        onChangeEnd: durationMs <= 0
            ? null
            : (v) {
                setState(() {
                  _dragging = false;
                  _seekTarget = v;
                });
                widget.onSeekEnd(v);
              },
      ),
    );
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final m = two(d.inMinutes.remainder(60));
    final s = two(d.inSeconds.remainder(60));
    if (d.inHours > 0) return '${two(d.inHours)}:$m:$s';
    return '$m:$s';
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.child,
    this.padding = const EdgeInsets.all(10),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: child,
      ),
    );
  }
}
