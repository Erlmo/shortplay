part of 'player_controls_overlay.dart';

// ─── 红果式播放页控件层 ──────────────────────────────────────────────────
// 竖屏：左下剧名/标签/简介（倍速/清晰度/弹幕/缓存都收进右上角“…”） + 底部“选集”栏 + 交界处细进度条；
//       单击暂停（中间大播放键），长按倍速。
// 横屏全屏：顶栏（返回、剧名·集数、时间）+ 左侧锁屏 + 底部进度行 + 操作行
//       （播放/下一集/弹幕 ｜ 倍速/清晰度/选集），选项从右侧深色面板滑出。
// 只用现有功能，不做点赞/评论等没有后端支持的入口。

const _kShadow = [Shadow(color: Colors.black54, blurRadius: 6)];
const _kHgRed = Color(0xFFFF2442);

String _fmtMs(int ms) {
  final d = Duration(milliseconds: ms < 0 ? 0 : ms);
  String two(int n) => n.toString().padLeft(2, '0');
  final m = two(d.inMinutes.remainder(60));
  final s = two(d.inSeconds.remainder(60));
  return d.inHours > 0 ? '${two(d.inHours)}:$m:$s' : '$m:$s';
}

String _speedLabel(double v) =>
    v == 1.0 ? '倍速' : '${v.toStringAsFixed(v == v.roundToDouble() ? 1 : 2)}x';

extension _HgLayouts on PlayerControlsOverlay {
  int get _epNo => episodeNumber ?? currentEpisodeIndex + 1;

  Widget get _likeButton => Semantics(
        button: true,
        toggled: isLiked,
        label: isLiked ? '取消喜欢' : '喜欢',
        child: Tooltip(
          message: isLiked ? '取消喜欢' : '喜欢',
          child: _BareIconButton(
            icon: isLiked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            color: isLiked ? _kHgRed : Colors.white,
            size: 24,
            onTap: onLikeTap,
          ),
        ),
      );

  Widget get _videoFitButton => Tooltip(
        message: isVideoFilled ? '切换为完整显示' : '铺满屏幕（等比例裁切）',
        child: _BareIconButton(
          icon: isVideoFilled
              ? Icons.fit_screen_rounded
              : Icons.crop_free_rounded,
          size: 24,
          onTap: onToggleVideoFit,
        ),
      );

  Future<void> _openSettings(BuildContext context, {bool side = false}) async {
    onMenuOpened();
    final action = await showPlayerMoreSheet(
      context: context,
      canDownload: canDownload,
      showDramaFeatures: !isDirectVideo,
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
      forceSidePanel: side,
      onSheetLayout: side ? null : onBottomPanelHeight,
    );
    if (!side) onBottomPanelHeight?.call(0);
    onMenuClosed();
    if (action != null) onMenuAction(action);
  }

  // ═══ 竖屏 ═══════════════════════════════════════════════════════════════
  Widget _buildHgPortrait(
      BuildContext context, MediaQueryData media, TextTheme textTheme) {
    const barH = PlayerVideoSurface.phoneBottomBarHeight;
    final areaH = media.size.height - barH;
    final landscapeVideo = videoWidth > 0 &&
        videoHeight > 0 &&
        videoWidth / videoHeight >= PlayerVideoSurface.landscapeRatio;
    final videoBounds = landscapeVideo
        ? PlayerVideoSurface.phoneVideoRect(
            media.size, videoWidth.toDouble(), videoHeight.toDouble())
        : Rect.zero;

    return Stack(
      children: [
        // 顶部淡渐变 + 返回 / 更多
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: media.viewPadding.top + 76,
          child: const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x66000000), Colors.transparent],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
              child: Row(children: [
                _BareIconButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    size: 20,
                    onTap: onBack),
                const Spacer(),
                if (onLikeTap != null) _likeButton,
                _BareIconButton(
                    icon: Icons.more_horiz,
                    size: 26,
                    onTap: () => _openSettings(context)),
              ]),
            ),
          ),
        ),
        if (isSpeedUp) _HgSpeedUpHint(top: media.viewPadding.top + 56),
        if (userPaused && seekingPositionMs == null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: areaH,
            child: const IgnorePointer(child: Center(child: _HgPausedIcon())),
          ),
        // 横版片源：画面下方“全屏观看”
        if (landscapeVideo && playerInitialized)
          Positioned(
            left: 0,
            right: 0,
            top: videoBounds.bottom + 8,
            child: Center(
              child: _HgPillButton(
                label: '全屏观看',
                onTap: onToggleLandscapeFullScreen,
              ),
            ),
          ),
        if (!isPageTransitioning) ...[
          // 左下：剧名 / 标签（底部选集栏最右侧的“全屏”可隐藏）
          Positioned(
            left: 16,
            right: 64,
            bottom: barH + 18,
            child: _HgInfoBlock(
              dramaName: dramaName,
              tags: dramaTags,
              onTitleTap: isDirectVideo ? null : onEpisodeTap,
            ),
          ),
          // 拖动进度时屏幕中间的大号时间
          if (seekingPositionMs != null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: areaH,
              child: IgnorePointer(
                child: Center(
                  child: _HgSeekTime(
                    positionMs: seekingPositionMs!.toInt(),
                    durationMsNotifier: durationMsNotifier,
                  ),
                ),
              ),
            ),
          // 底部固定“选集”栏
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: barH,
            child: _HgEpisodeBar(
              episodeNumber: _epNo,
              totalEpisodes: totalEpisodes,
              onTap: isDirectVideo ? onTogglePlay : onEpisodeTap,
              isDirectVideo: isDirectVideo,
              playingNotifier: playingNotifier,
              time: _HgTimeLabel(
                positionMsNotifier: positionMsNotifier,
                durationMsNotifier: durationMsNotifier,
                seekingPositionMs: seekingPositionMs,
              ),
            ),
          ),
          // 细线位置不变，触摸范围限制在上下 12dp，避免覆盖选集栏。
          Positioned(
            // 时间预览插入/移除时保留 Slider，避免手势被卸载提前取消。
            key: const ValueKey('portrait-playback-progress'),
            left: PlayerVideoSurface.phoneBarCornerRadius,
            right: PlayerVideoSurface.phoneBarCornerRadius,
            top: areaH - PlayerControlsOverlay._portraitSeekTouchHeight / 2,
            height: PlayerControlsOverlay._portraitSeekTouchHeight,
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
              sliderOnly: true,
              edgeToEdge: true,
            ),
          ),
        ],
      ],
    );
  }

  // ═══ 横屏全屏 ═══════════════════════════════════════════════════════════
  Widget _buildHgLandscape(BuildContext context, MediaQueryData media) {
    return _HgLandscapeLayer(c: this, media: media);
  }
}

// ─── 竖屏组件 ─────────────────────────────────────────────────────────────

class _HgPausedIcon extends StatelessWidget {
  const _HgPausedIcon();
  @override
  Widget build(BuildContext context) => Icon(
        Icons.play_arrow_rounded,
        size: 76,
        color: Colors.white.withValues(alpha: 0.82),
        shadows: const [Shadow(color: Colors.black38, blurRadius: 16)],
      );
}

class _HgSpeedUpHint extends StatelessWidget {
  const _HgSpeedUpHint({required this.top});
  final double top;
  @override
  Widget build(BuildContext context) => Positioned(
        top: top,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.fast_forward_rounded, color: Colors.white, size: 16),
                SizedBox(width: 6),
                Text('2倍速快进中',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      );
}

/// 横版片源画面下方的“全屏观看”按钮：小号、细边、小圆角，配横屏手机图标
class _HgPillButton extends StatelessWidget {
  const _HgPillButton({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          // 外圈透明留白，扩大点击区域，按钮本身保持小巧
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: const Color(0x59000000),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CustomPaint(painter: _HgLandscapeIconPainter()),
                ),
                const SizedBox(width: 5),
                Text(label,
                    style: const TextStyle(
                        color: Color(0xF2FFFFFF),
                        fontSize: 12,
                        height: 1.0,
                        leadingDistribution: TextLeadingDistribution.even,
                        fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ),
      );
}

/// 横屏图标：横放的手机外框（右侧一个小听筒点），左上一段带箭头的旋转弧线
class _HgLandscapeIconPainter extends CustomPainter {
  const _HgLandscapeIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 15;
    final stroke = Paint()
      ..color = const Color(0xF2FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 横放的手机
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(1.2 * k, 6 * k, 12.6 * k, 7.6 * k),
          Radius.circular(1.6 * k)),
      stroke,
    );
    canvas.drawCircle(Offset(11.6 * k, 9.8 * k), 0.55 * k,
        Paint()..color = const Color(0xF2FFFFFF));

    // 旋转弧线 + 箭头
    final arc = Path()
      ..moveTo(2.2 * k, 4.2 * k)
      ..quadraticBezierTo(4 * k, 1.2 * k, 7.6 * k, 1.6 * k);
    canvas.drawPath(arc, stroke);
    final head = Path()
      ..moveTo(6.2 * k, 0.4 * k)
      ..lineTo(7.8 * k, 1.6 * k)
      ..lineTo(6.4 * k, 3.0 * k);
    canvas.drawPath(head, stroke);
  }

  @override
  bool shouldRepaint(covariant _HgLandscapeIconPainter oldDelegate) => false;
}

/// 清屏状态：放在顶层，翻到下一集时保持不变。
final ValueNotifier<bool> _hgInfoHidden = ValueNotifier(false);

class _HgInfoBlock extends StatelessWidget {
  const _HgInfoBlock({
    required this.dramaName,
    required this.tags,
    required this.onTitleTap,
  });
  final String dramaName;
  final List<String> tags;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final tags = this.tags.where((t) => t.trim().isNotEmpty).take(4).toList();
    return ValueListenableBuilder<bool>(
      valueListenable: _hgInfoHidden,
      builder: (context, hidden, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: hidden
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (dramaName.isNotEmpty)
                        GestureDetector(
                          onTap: onTitleTap,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Flexible(
                              child: Text(
                                dramaName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    shadows: _kShadow),
                              ),
                            ),
                          ]),
                        ),
                      if (tags.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final t in tags)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(t,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12)),
                            ),
                        ]),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _HgTimeLabel extends StatelessWidget {
  const _HgTimeLabel({
    required this.positionMsNotifier,
    required this.durationMsNotifier,
    required this.seekingPositionMs,
  });
  final ValueNotifier<int> positionMsNotifier;
  final ValueNotifier<int>? durationMsNotifier;
  final double? seekingPositionMs;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([
          positionMsNotifier,
          if (durationMsNotifier != null) durationMsNotifier
        ]),
        builder: (context, _) {
          final dur = durationMsNotifier?.value ?? 0;
          if (dur <= 0) return const SizedBox.shrink();
          final pos = seekingPositionMs?.toInt() ?? positionMsNotifier.value;
          return Text(
            '${_fmtMs(pos)} / ${_fmtMs(dur)}',
            style: const TextStyle(
              color: Color(0x99FFFFFF),
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          );
        },
      );
}

class _HgSeekTime extends StatelessWidget {
  const _HgSeekTime({required this.positionMs, this.durationMsNotifier});
  final int positionMs;
  final ValueNotifier<int>? durationMsNotifier;
  @override
  Widget build(BuildContext context) {
    final dur = durationMsNotifier?.value ?? 0;
    return Text.rich(
      TextSpan(children: [
        TextSpan(
            text: _fmtMs(positionMs),
            style: const TextStyle(color: Colors.white)),
        TextSpan(
            text: '  /  ${_fmtMs(dur)}',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
      ]),
      style: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        fontFeatures: [FontFeature.tabularFigures()],
        shadows: _kShadow,
      ),
    );
  }
}

class _HgEpisodeBar extends StatelessWidget {
  const _HgEpisodeBar({
    required this.episodeNumber,
    required this.totalEpisodes,
    required this.onTap,
    this.isDirectVideo = false,
    this.playingNotifier,
    this.time,
  });
  final int episodeNumber;
  final int totalEpisodes;
  final bool isDirectVideo;
  final ValueNotifier<bool>? playingNotifier;
  final VoidCallback onTap;

  /// 播放时间（当前 / 总时长），显示在全屏按钮左边
  final Widget? time;
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          color: PlayerVideoSurface.phoneBarColor,
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          child: Row(children: [
            if (isDirectVideo)
              ValueListenableBuilder<bool>(
                valueListenable: playingNotifier!,
                builder: (_, playing, __) => _BareIconButton(
                  icon:
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 25,
                  onTap: onTap,
                ),
              )
            else ...[
              const SizedBox(
                width: 18,
                height: 18,
                child: CustomPaint(painter: _HgEpisodeIconPainter()),
              ),
              const SizedBox(width: 8),
              // 放在同一段文字里：字号不同的两部分共用一条基线，不会一高一低；
              // 分隔竖线用 WidgetSpan 按行中线放
              Text.rich(
                TextSpan(children: [
                  const TextSpan(
                    text: '选集',
                    style: TextStyle(
                      color: Color(0xF2FFFFFF),
                      fontSize: 14,
                      letterSpacing: 0.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Container(
                      width: 1,
                      height: 10,
                      margin: const EdgeInsets.symmetric(horizontal: 9),
                      color: const Color(0x2EFFFFFF),
                    ),
                  ),
                  TextSpan(
                    text: '第$episodeNumber集',
                    style: const TextStyle(color: Color(0xCCFFFFFF)),
                  ),
                  if (totalEpisodes > 0)
                    TextSpan(
                      text: '  共$totalEpisodes集',
                      style: const TextStyle(color: Color(0x66FFFFFF)),
                    ),
                ]),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.0,
                  leadingDistribution: TextLeadingDistribution.even,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right_rounded,
                  color: Color(0x66FFFFFF), size: 16),
            ],
            const Spacer(),
            if (time != null) IgnorePointer(child: time!),
            // 最右侧：全屏（清屏，只隐藏剧名和标签）
            ValueListenableBuilder<bool>(
              valueListenable: _hgInfoHidden,
              builder: (context, hidden, _) => Tooltip(
                message: hidden ? '退出全屏' : '全屏',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _hgInfoHidden.value = !hidden,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      hidden
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      color: const Color(0xE6FFFFFF),
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
}
