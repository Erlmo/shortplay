import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../models/danmaku.dart';
import '../utils/emoji_map.dart';

class _DanmakuItem {
  double x;
  final double width;
  final double speed;
  final TextPainter painter;

  _DanmakuItem({
    required this.x,
    required this.width,
    required this.speed,
    required this.painter,
  });
}

class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({
    super.key,
    required this.comments,
    required this.getPositionMs,
    this.isPlaying = true,
    this.visible = true,
    this.playbackSpeed = 1.0,
    this.fontSize = 14.0,
    this.opacity = 0.85,
    this.maxTracks = 3,
    this.durationMs = 5000,
    this.topOffset,
  });

  final List<DanmakuComment> comments;
  final int Function() getPositionMs;
  final bool isPlaying;
  final bool visible;
  final double playbackSpeed;
  final double fontSize;
  final double opacity;
  final int maxTracks;
  final int durationMs;
  final double? topOffset;

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _DanmakuLayerState extends State<DanmakuLayer>
    with SingleTickerProviderStateMixin {
  final List<List<_DanmakuItem>> _tracks = [];
  final Set<String> _dispatched = {};
  final List<DanmakuComment> _pending = [];
  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  int _lastPositionMs = -1;
  final _random = Random();
  final _repaintNotifier = _RepaintNotifier();

  @override
  void initState() {
    super.initState();
    _initTracks();
    _ticker = createTicker(_onTick)..start();
  }

  void _initTracks() {
    _tracks.clear();
    for (int i = 0; i < widget.maxTracks; i++) {
      _tracks.add([]);
    }
  }

  @override
  void didUpdateWidget(DanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.maxTracks != oldWidget.maxTracks) _initTracks();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaintNotifier.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMilliseconds;
    _lastElapsed = elapsed;
    if (dt <= 0 || dt > 100) return;
    if (!widget.isPlaying) return;

    final currentMs = widget.getPositionMs();
    if (_lastPositionMs < 0) {
      _lastPositionMs = currentMs;
      return;
    }

    final diff = currentMs - _lastPositionMs;
    if (diff < -2000) {
      _clearAll();
      _lastPositionMs = currentMs;
      _repaintNotifier.notify();
      return;
    }
    if (diff > 3000) {
      _skipForward(currentMs);
      _lastPositionMs = currentMs;
      _repaintNotifier.notify();
      return;
    }

    final delta = dt * widget.playbackSpeed;
    bool changed = false;
    for (final track in _tracks) {
      track.removeWhere((item) => item.x + item.width < -10);
      for (final item in track) {
        item.x -= item.speed * delta;
      }
      if (track.isNotEmpty) changed = true;
    }

    if (widget.visible) _flushPending();

    if (currentMs > _lastPositionMs) {
      for (final comment in widget.comments) {
        if (_dispatched.contains(comment.id)) continue;
        if (comment.fireAtMs > _lastPositionMs &&
            comment.fireAtMs <= currentMs) {
          _dispatched.add(comment.id);
          if (widget.visible) {
            if (!_tryAddToTrack(comment.content)) {
              _pending.add(comment);
            }
          }
          changed = true;
        }
      }
      _lastPositionMs = currentMs;
    }

    if (changed) _repaintNotifier.notify();
  }

  void _clearAll() {
    for (final track in _tracks) {
      track.clear();
    }
    _dispatched.clear();
    _pending.clear();
  }

  void _skipForward(int targetMs) {
    for (final comment in widget.comments) {
      if (comment.fireAtMs <= targetMs) {
        _dispatched.add(comment.id);
      }
    }
    _pending.clear();
  }

  void _flushPending() {
    if (_pending.isEmpty) return;
    final retry = List<DanmakuComment>.from(_pending);
    _pending.clear();
    for (final comment in retry) {
      if (!_tryAddToTrack(comment.content)) {
        _pending.add(comment);
      }
    }
    if (_pending.length > 20) {
      _pending.removeRange(0, _pending.length - 20);
    }
  }

  bool _tryAddToTrack(String content) {
    final resolved = replaceDanmakuEmoji(content);
    final screenWidth = MediaQuery.of(context).size.width;
    final tp = TextPainter(
      text: TextSpan(
        text: resolved,
        style: TextStyle(
          fontSize: widget.fontSize,
          color: Colors.white,
          shadows: const [
            Shadow(
              offset: Offset(1, 1),
              blurRadius: 2,
              color: Color(0xDD000000),
            ),
          ],
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final textWidth = tp.width + 16;
    final totalDistance = screenWidth + textWidth;
    final baseSpeed = totalDistance / widget.durationMs;
    final speed = baseSpeed * (0.95 + _random.nextDouble() * 0.1);

    for (int i = 0; i < _tracks.length; i++) {
      if (_canInsert(i, screenWidth)) {
        _tracks[i].add(
          _DanmakuItem(
            x: screenWidth,
            width: textWidth,
            speed: speed,
            painter: tp,
          ),
        );
        return true;
      }
    }
    tp.dispose();
    return false;
  }

  bool _canInsert(int trackIndex, double screenWidth) {
    if (_tracks[trackIndex].isEmpty) return true;
    final last = _tracks[trackIndex].last;
    return last.x + last.width < screenWidth * 0.7;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    final trackHeight = widget.fontSize + 12;
    final topOffset =
        widget.topOffset ?? MediaQuery.of(context).viewPadding.top + 80;
    return IgnorePointer(
      child: Opacity(
        opacity: widget.opacity,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _DanmakuPainter(
              tracks: _tracks,
              trackHeight: trackHeight,
              topOffset: topOffset,
              repaint: _repaintNotifier,
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _RepaintNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _DanmakuPainter extends CustomPainter {
  final List<List<_DanmakuItem>> tracks;
  final double trackHeight;
  final double topOffset;

  _DanmakuPainter({
    required this.tracks,
    required this.trackHeight,
    required this.topOffset,
    required _RepaintNotifier repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < tracks.length; i++) {
      final y = topOffset + i * trackHeight;
      for (final item in tracks[i]) {
        item.painter.paint(canvas, Offset(item.x, y));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => false;
}
