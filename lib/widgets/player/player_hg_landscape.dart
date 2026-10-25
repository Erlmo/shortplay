part of 'player_controls_overlay.dart';

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

  /// 横屏清晰度：从清晰度按钮正上方弹出一列选项（[anchor] 为按钮的 context）。
  Future<void> _openQuality(BuildContext anchor) async {
    final c = widget.c;
    final loader = c.loadQualities;
    if (loader == null || c.onQualityChanged == null) return;
    List<String> values;
    try {
      values = await loader();
    } catch (_) {
      return;
    }
    if (!mounted || !anchor.mounted || values.isEmpty) return;
    c.onMenuOpened();
    final picked = await _showOptionsAbove<String>(
      anchor: anchor,
      values: values.reversed.toList(),
      selected: c.currentQuality,
      label: (v) => v.toUpperCase(),
    );
    c.onMenuClosed();
    if (picked != null && picked != c.currentQuality) {
      c.onQualityChanged!(picked);
    }
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
          key: const ValueKey('landscape-playback-controls'),
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
                if (c.onToggleVideoFit != null && c.playerInitialized)
                  c._videoFitButton,
                if (c.loadQualities != null && c.currentQuality.isNotEmpty)
                  Builder(
                    builder: (anchor) => _HgTextButton(
                        label: c.currentQuality.toUpperCase(),
                        onTap: () => _openQuality(anchor)),
                  ),
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

/// 在 [anchor]（底栏按钮）正上方弹出一列选项，点外面关闭。返回选中的值。
Future<T?> _showOptionsAbove<T>({
  required BuildContext anchor,
  required List<T> values,
  required T selected,
  required String Function(T) label,
}) {
  final box = anchor.findRenderObject() as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  // 用 PopupRoute（showGeneralDialog）而不是 PageRoute：播放页通过 RouteAware
  // 在有新页面盖上来时自动暂停，弹个选项菜单不应触发暂停。
  return showGeneralDialog<T>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (context, _, __) => _HgAnchoredOptions<T>(
      anchorRect: rect,
      values: values,
      selected: selected,
      label: label,
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.03), end: Offset.zero)
              .animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// 贴着按钮上沿、水平居中的深色选项卡片。
class _HgAnchoredOptions<T> extends StatelessWidget {
  const _HgAnchoredOptions({
    required this.anchorRect,
    required this.values,
    required this.selected,
    required this.label,
  });

  final Rect anchorRect;
  final List<T> values;
  final T selected;
  final String Function(T) label;

  static const double _width = 104;
  static const double _itemHeight = 42;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final left = (anchorRect.center.dx - _width / 2)
        .clamp(8.0, screen.width - _width - 8.0);
    final bottom = screen.height - anchorRect.top + 6;
    return Stack(children: [
      // 点卡片以外的地方关闭
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
        ),
      ),
      Positioned(
        left: left,
        bottom: bottom,
        width: _width,
        child: Material(
          color: const Color(0xE6161618),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: math.max(_itemHeight, anchorRect.top - 16)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final v in values)
                  InkWell(
                    onTap: () => Navigator.of(context).pop(v),
                    child: SizedBox(
                      height: _itemHeight,
                      width: double.infinity,
                      child: Center(
                        child: Text(
                          label(v),
                          style: TextStyle(
                            color: v == selected
                                ? _kHgRed
                                : Colors.white.withValues(alpha: 0.88),
                            fontSize: 14,
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
      ),
    ]);
  }
}

/// 横屏右侧面板里的单选列表（倍速）。
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

/// 选集图标：两张叠放的圆角卡片，前面一张里有个小播放三角。
/// 线宽 1.4、和文字同色，比系统的 video_library 图标更轻、更精致。
class _HgEpisodeIconPainter extends CustomPainter {
  const _HgEpisodeIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 18;
    final stroke = Paint()
      ..color = const Color(0xF2FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 * s
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    // 后面那张卡片只露出上沿
    final back = Path()
      ..moveTo(4.5 * s, 3 * s)
      ..lineTo(13.5 * s, 3 * s);
    canvas.drawPath(back, stroke..color = const Color(0x8CFFFFFF));

    // 前面的卡片
    stroke.color = const Color(0xF2FFFFFF);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(2 * s, 5.5 * s, 14 * s, 10.5 * s),
          Radius.circular(2.6 * s)),
      stroke,
    );

    // 小播放三角
    final tri = Path()
      ..moveTo(7.6 * s, 8.4 * s)
      ..lineTo(11.6 * s, 10.75 * s)
      ..lineTo(7.6 * s, 13.1 * s)
      ..close();
    canvas.drawPath(tri, Paint()..color = const Color(0xF2FFFFFF));
  }

  @override
  bool shouldRepaint(covariant _HgEpisodeIconPainter oldDelegate) => false;
}
