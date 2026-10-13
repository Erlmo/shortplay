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

  Future<void> _openSettings(BuildContext context, {bool side = false}) async {
    onMenuOpened();
    final action = await showPlayerMoreSheet(
      context: context,
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
    final barH = PlayerVideoSurface.phoneBottomBarHeight(media);
    final areaH = media.size.height - barH;
    final landscapeVideo = videoWidth > 0 &&
        videoHeight > 0 &&
        videoWidth / videoHeight >= PlayerVideoSurface.landscapeRatio;

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
            top: media.size.height / 2 +
                media.size.width * videoHeight / videoWidth / 2 +
                16,
            child: Center(
              child: _HgPillButton(
                icon: Icons.fullscreen_rounded,
                label: '全屏观看',
                onTap: onToggleLandscapeFullScreen,
              ),
            ),
          ),
        if (!isPageTransitioning) ...[
          // 底部信息区垫渐变
          Positioned(
            left: 0,
            right: 0,
            bottom: barH,
            height: 220,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0x99000000), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
          // 左下：剧名 / 标签（底部选集栏最右侧的“全屏”可隐藏）
          Positioned(
            left: 16,
            right: 64,
            bottom: barH + 18,
            child: _HgInfoBlock(
              dramaName: dramaName,
              tags: dramaTags,
              onTitleTap: onEpisodeTap,
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
              bottomInset: media.viewPadding.bottom,
              onTap: onEpisodeTap,
              time: _HgTimeLabel(
                positionMsNotifier: positionMsNotifier,
                durationMsNotifier: durationMsNotifier,
                seekingPositionMs: seekingPositionMs,
              ),
            ),
          ),
          // 细进度条：紧贴选集栏上沿，左右收进到圆角以内
          Positioned(
            left: PlayerVideoSurface.phoneBarCornerRadius,
            right: PlayerVideoSurface.phoneBarCornerRadius,
            top: areaH - 12,
            height: 24,
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

class _HgPillButton extends StatelessWidget {
  const _HgPillButton({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      );
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
  final VoidCallback onTitleTap;

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
    required this.bottomInset,
    required this.onTap,
    this.time,
  });
  final int episodeNumber;
  final int totalEpisodes;
  final double bottomInset;
  final VoidCallback onTap;

  /// 播放时间（当前 / 总时长），显示在全屏按钮左边
  final Widget? time;
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          color: PlayerVideoSurface.phoneBarColor,
          padding: EdgeInsets.fromLTRB(16, 0, 4, bottomInset),
          child: Row(children: [
            const Icon(Icons.video_library_rounded,
                color: Colors.white, size: 18),
            const SizedBox(width: 8),
            const Text('选集',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            Text(
              totalEpisodes > 0
                  ? ' · 第$episodeNumber集 / 全$totalEpisodes集'
                  : ' · 第$episodeNumber集',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 14),
            ),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.6), size: 22),
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
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
}

// ─── 横屏组件 ─────────────────────────────────────────────────────────────

class _HgLandscapeLayer extends StatefulWidget {
  const _HgLandscapeLayer({required this.c, required this.media});
  final PlayerControlsOverlay c;
  final MediaQueryData media;
  @override
  State<_HgLandscapeLayer> createState() => _HgLandscapeLayerState();
}

class _HgLandscapeLayerState extends State<_HgLandscapeLayer> {
  bool _locked = false;
  bool _showLock = true;
  Timer? _lockHintTimer;

  @override
  void dispose() {
    _lockHintTimer?.cancel();
    super.dispose();
  }

  void _flashLock() {
    setState(() => _showLock = true);
    _lockHintTimer?.cancel();
    _lockHintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showLock = false);
    });
  }

  Future<void> _openOptions<T>({
    required String title,
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) async {
    final c = widget.c;
    c.onMenuOpened();
    final picked = await showSidePanel<T>(
      context: context,
      widthFraction: 0.3,
      minWidth: 260,
      color: const Color(0xF0141414),
      barrierColor: Colors.black.withAlpha(40),
      builder: (context) => _HgOptionList<T>(
        title: title,
        values: values,
        selected: selected,
        label: label,
      ),
    );
    c.onMenuClosed();
    if (picked != null) onChanged(picked);
  }

  Future<void> _openQuality() async {
    final c = widget.c;
    final loader = c.loadQualities;
    if (loader == null || c.onQualityChanged == null) return;
    List<String> values;
    try {
      values = await loader();
    } catch (_) {
      return;
    }
    if (!mounted || values.isEmpty) return;
    await _openOptions<String>(
      title: '清晰度',
      values: values.reversed.toList(),
      selected: c.currentQuality,
      label: (v) => v.toUpperCase(),
      onChanged: c.onQualityChanged!,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final media = widget.media;
    final pad = EdgeInsets.only(
      left: math.max(24.0, media.viewPadding.left),
      right: math.max(24.0, media.viewPadding.right),
    );
    final showUi = c.showLandscapeUI && !_locked;

    return Stack(children: [
      // 锁定时吞掉所有手势，只允许点出解锁按钮
      if (_locked)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _flashLock,
          ),
        ),
      if (c.isSpeedUp) const _HgSpeedUpHint(top: 28),
      if (c.userPaused && !_locked)
        const IgnorePointer(child: Center(child: _HgPausedIcon())),
      if (c.seekingPositionMs != null)
        IgnorePointer(
          child: Center(
            child: _HgSeekTime(
              positionMs: c.seekingPositionMs!.toInt(),
              durationMsNotifier: c.durationMsNotifier,
            ),
          ),
        ),
      // 顶栏
      if (showUi)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: pad.copyWith(top: 12, bottom: 28),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x99000000), Colors.transparent],
              ),
            ),
            child: Row(children: [
              _BareIconButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  size: 20,
                  onTap: c.onToggleLandscapeFullScreen),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  c.dramaName.isEmpty
                      ? '第${c._epNo}集'
                      : '${c.dramaName}  第${c._epNo}集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      shadows: _kShadow),
                ),
              ),
              const _HgClock(),
              const SizedBox(width: 8),
              _BareIconButton(
                  icon: Icons.more_horiz,
                  size: 24,
                  onTap: () => c._openSettings(context, side: true)),
            ]),
          ),
        ),
      // 左侧锁屏
      if (showUi || (_locked && _showLock))
        Positioned(
          left: pad.left,
          top: 0,
          bottom: 0,
          child: Center(
            child: GestureDetector(
              onTap: () {
                setState(() => _locked = !_locked);
                if (_locked) _flashLock();
              },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      // 底部：进度行 + 操作行
      if (showUi)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: pad.copyWith(top: 36, bottom: 10),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xB3000000), Colors.transparent],
              ),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _HgLandscapeProgress(c: c),
              const SizedBox(height: 2),
              Row(children: [
                ValueListenableBuilder<bool>(
                  valueListenable: c.playingNotifier,
                  builder: (context, playing, _) => _BareIconButton(
                    icon: playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 30,
                    onTap: c.onTogglePlay,
                  ),
                ),
                if (c.onNextEpisode != null)
                  _BareIconButton(
                      icon: Icons.skip_next_rounded,
                      size: 28,
                      onTap: c.onNextEpisode),
                _BareIconButton(
                  icon: c.danmakuEnabled
                      ? Icons.subtitles_rounded
                      : Icons.subtitles_off_outlined,
                  size: 24,
                  onTap: c.onToggleDanmaku,
                ),
                const Spacer(),
                if (c.onSpeedChanged != null)
                  _HgTextButton(
                    label: _speedLabel(c.playbackSpeed),
                    onTap: () => _openOptions<double>(
                      title: '倍速',
                      values: const [3.0, 2.0, 1.5, 1.25, 1.0, 0.75],
                      selected: c.playbackSpeed,
                      label: (v) => v == 1.0 ? '1.0x 正常' : '${v}x',
                      onChanged: c.onSpeedChanged!,
                    ),
                  ),
                if (c.loadQualities != null && c.currentQuality.isNotEmpty)
                  _HgTextButton(
                      label: c.currentQuality.toUpperCase(),
                      onTap: _openQuality),
                _HgTextButton(label: '选集', onTap: c.onEpisodeTap),
              ]),
            ]),
          ),
        ),
    ]);
  }
}

class _HgLandscapeProgress extends StatelessWidget {
  const _HgLandscapeProgress({required this.c});
  final PlayerControlsOverlay c;
  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Row(children: [
      ListenableBuilder(
        listenable: c.positionMsNotifier,
        builder: (context, _) => Text(
            _fmtMs(c.seekingPositionMs?.toInt() ?? c.positionMsNotifier.value),
            style: style),
      ),
      Expanded(
        child: SizedBox(
          height: 28,
          child: _PlaybackProgressBar(
            player: c.player,
            positionMsNotifier: c.positionMsNotifier,
            playingNotifier: c.playingNotifier,
            seekingPositionMs: c.seekingPositionMs,
            onTogglePlay: c.onTogglePlay,
            onSeekStart: c.onSeekStart,
            onSeekChanged: c.onSeekChanged,
            onSeekEnd: c.onSeekEnd,
            durationMsNotifier: c.durationMsNotifier,
            sliderOnly: true,
          ),
        ),
      ),
      if (c.durationMsNotifier != null)
        ValueListenableBuilder<int>(
          valueListenable: c.durationMsNotifier!,
          builder: (context, dur, _) => Text(_fmtMs(dur), style: style),
        ),
    ]);
  }
}

class _HgTextButton extends StatelessWidget {
  const _HgTextButton({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  shadows: _kShadow)),
        ),
      );
}

class _HgClock extends StatefulWidget {
  const _HgClock();
  @override
  State<_HgClock> createState() => _HgClockState();
}

class _HgClockState extends State<_HgClock> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return Text('${two(now.hour)}:${two(now.minute)}',
        style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            shadows: _kShadow));
  }
}

/// 横屏右侧面板里的单选列表（倍速 / 清晰度）。
class _HgOptionList<T> extends StatelessWidget {
  const _HgOptionList({
    required this.title,
    required this.values,
    required this.selected,
    required this.label,
  });
  final String title;
  final List<T> values;
  final T selected;
  final String Function(T) label;
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Row(children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final v in values)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).pop(v),
                      child: SizedBox(
                        height: 48,
                        width: double.infinity,
                        child: Center(
                          child: Text(
                            label(v),
                            style: TextStyle(
                              color: v == selected
                                  ? _kHgRed
                                  : Colors.white.withValues(alpha: 0.85),
                              fontSize: 16,
                              fontWeight: v == selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ],
      );
}
