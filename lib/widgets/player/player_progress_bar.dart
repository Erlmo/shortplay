part of 'player_controls_overlay.dart';

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
    this.sliderOnly = false,
    this.edgeToEdge = false,
  });

  /// 只画一条细进度条（竖屏手机布局，放在画面与控件栏交界处）
  final bool sliderOnly;

  /// 轨道紧贴左右边缘（红果竖屏：进度条压在画面与选集栏交界处，通栏）
  final bool edgeToEdge;
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
  int? _seekPointer;
  double? _pointerFraction;

  void _updateDragValue(double value) {
    if (_dragValue == value) return;
    setState(() => _dragValue = value);
    widget.onSeekChanged(value);
  }

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

        if (widget.sliderOnly) {
          return _buildSlider(context, durationMs, displayPositionMs);
        }

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

    final thin = widget.sliderOnly;
    final slider = SliderTheme(
      data: SliderTheme.of(ctx).copyWith(
        trackHeight: thin
            ? (widget.edgeToEdge ? (_dragging ? 3 : 1) : (_dragging ? 4 : 2))
            : 3,
        trackShape: widget.edgeToEdge ? const _EdgeToEdgeTrackShape() : null,
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: thin
              ? (widget.edgeToEdge
                  ? (_dragging ? 4 : 1.75)
                  : (_dragging ? 7 : 4))
              : PlayerControlsOverlay._seekThumbRadius,
        ),
        overlayShape: RoundSliderOverlayShape(overlayRadius: thin ? 12 : 14),
        activeTrackColor:
            Colors.white.withValues(alpha: widget.edgeToEdge ? 0.6 : 0.92),
        inactiveTrackColor: Colors.white.withValues(alpha: 0.20),
        thumbColor: Colors.white,
        overlayColor: Colors.white.withValues(alpha: 0.12),
      ),
      child: Slider(
        allowedInteraction: SliderInteraction.tapAndSlide,
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
                _updateDragValue(widget.edgeToEdge && _pointerFraction != null
                    ? _pointerFraction! * max
                    : v);
              },
        onChangeEnd: durationMs <= 0
            ? null
            : (v) {
                final target = _dragValue;
                setState(() {
                  _dragging = false;
                  _seekTarget = target;
                });
                widget.onSeekEnd(target);
              },
      ),
    );
    if (!widget.edgeToEdge) return slider;

    // 保留 Slider 的手势仲裁、键盘和无障碍操作；触摸拖动按绝对位置计算，
    // 避免起拖阈值及移动事件的相对位移累积让圆点落后于手指。
    return LayoutBuilder(builder: (context, constraints) {
      void recordPosition(int pointer, double x) {
        if (_seekPointer != pointer || constraints.maxWidth <= 0) return;
        final fraction = (x / constraints.maxWidth).clamp(0.0, 1.0);
        _pointerFraction = Directionality.of(context) == TextDirection.rtl
            ? 1 - fraction
            : fraction;
        if (_dragging) _updateDragValue(_pointerFraction! * max);
      }

      void releasePointer(int pointer) {
        if (_seekPointer != pointer) return;
        _seekPointer = null;
        _pointerFraction = null;
      }

      return Listener(
        onPointerDown: (event) {
          if (_seekPointer != null) return;
          _seekPointer = event.pointer;
          recordPosition(event.pointer, event.localPosition.dx);
        },
        onPointerMove: (event) =>
            recordPosition(event.pointer, event.localPosition.dx),
        onPointerUp: (event) => releasePointer(event.pointer),
        onPointerCancel: (event) => releasePointer(event.pointer),
        child: slider,
      );
    });
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

class _BareIconButton extends StatelessWidget {
  const _BareIconButton(
      {required this.icon,
      this.size = 22,
      this.onTap,
      this.color = Colors.white});

  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Icon(
          icon,
          color: color,
          size: size,
          shadows: const [Shadow(color: Colors.black38, blurRadius: 6)],
        ),
      ),
    );
  }
}

/// 去掉 Slider 默认的左右留白（按拇指/光晕半径内缩），轨道占满整个宽度。
class _EdgeToEdgeTrackShape extends RoundedRectSliderTrackShape {
  const _EdgeToEdgeTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 2;
    final top = offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(offset.dx, top, parentBox.size.width, trackHeight);
  }

  /// 已播放部分和未播放部分同样粗；两段颜色在左右两端都很淡、往中间渐变到
  /// 正常色，让进度条两头柔和地融进画面边缘。
  static const double _fadeStop = 0.35;

  Shader _fade(Rect track, Color c) {
    final faint = c.withValues(alpha: c.a * 0.08);
    return LinearGradient(
      colors: [faint, c, c, faint],
      stops: const [0, _fadeStop, 1 - _fadeStop, 1],
    ).createShader(track);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (track.width <= 0) return;
    final radius = Radius.circular(track.height / 2);
    final canvas = context.canvas;
    final inactive = sliderTheme.inactiveTrackColor ?? const Color(0x33FFFFFF);
    final active = sliderTheme.activeTrackColor ?? const Color(0x99FFFFFF);

    canvas.drawRRect(RRect.fromRectAndRadius(track, radius),
        Paint()..shader = _fade(track, inactive));

    final playedRight = thumbCenter.dx.clamp(track.left, track.right);
    if (playedRight > track.left) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB(track.left, track.top, playedRight, track.bottom),
            radius),
        Paint()..shader = _fade(track, active),
      );
    }
  }
}
