import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/danmaku.dart';
import '../utils/emoji_map.dart';

/// 弹幕里的一段：一段文字（白字 + 描边两层），或一张表情图。
class _Piece {
  _Piece.text(TextPainter this.fill, TextPainter this.stroke)
      : image = null,
        width = fill.width;
  _Piece.image(ui.Image this.image, this.width)
      : fill = null,
        stroke = null;

  final TextPainter? fill;
  final TextPainter? stroke;
  final ui.Image? image;
  final double width;

  void dispose() {
    fill?.dispose();
    stroke?.dispose();
  }
}

class _DanmakuItem {
  double x;
  final double width;
  final double speed;
  final List<_Piece> pieces;

  _DanmakuItem({
    required this.x,
    required this.width,
    required this.speed,
    required this.pieces,
  });

  void dispose() {
    for (final p in pieces) {
      p.dispose();
    }
  }
}

/// 53 个弹幕表情（assets/danmaku_emoji）的解码图片，全局只加载一次。
class _EmojiImages {
  static final Map<String, ui.Image> cache = {};
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= _loadAll();

  static Future<void> _loadAll() async {
    final assets = danmakuEmojiAssets.toSet();
    await Future.wait(assets.map((asset) async {
      try {
        final data = await rootBundle.load(asset);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        cache[asset] = frame.image;
      } catch (e) {
        debugPrint('[DANMAKU] 表情图片加载失败 $asset: $e');
      }
    }));
  }
}

// ─── 红果弹幕参数（kmp_video_danmaku / DDanmakuEngine 反编译）────────────
// · 时间点：每条弹幕在自己的 offset_time 出现（见 DanmakuService）。
// · 滚动时长：竖屏 10000ms、横屏 12000ms，再除以“弹幕速度 × 播放倍速”。
// · 字号：默认 16sp（DanmakuTextSize.DEFAULT），白字 #FFFFFF + #8F000000 描边。
// · 不透明度：默认 255（完全不透明）。
// · 同一行相邻两条之间至少隔 48dp（horizontalMargin），行间距 4dp。
// · 后发的弹幕不能在屏幕内追上前一条；放不下的弹幕最多等 2 秒，过时就丢弃，
//   不会拖到很久以后才出来。

class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({
    super.key,
    required this.comments,
    required this.getPositionMs,
    this.isPlaying = true,
    this.visible = true,
    this.playbackSpeed = 1.0,
    this.fontSize = 16.0,
    this.opacity = 1.0,
    this.maxTracks = 3,
    this.durationMs = 10000,
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
  static const double _gap = 48;
  static const int _maxLateMs = 2000;
  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  int _lastPositionMs = -1;
  final _random = Random();
  final _repaintNotifier = _RepaintNotifier();

  @override
  void initState() {
    super.initState();
    _initTracks();
    unawaited(_EmojiImages.load());
    _ticker = createTicker(_onTick)..start();
  }

  void _initTracks() {
    for (final track in _tracks) {
      for (final item in track) {
        item.dispose();
      }
    }
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
    for (final track in _tracks) {
      for (final item in track) {
        item.dispose();
      }
    }
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
      track.removeWhere((item) {
        final gone = item.x + item.width < -10;
        if (gone) item.dispose();
        return gone;
      });
      for (final item in track) {
        item.x -= item.speed * delta;
      }
      if (track.isNotEmpty) changed = true;
    }

    if (widget.visible) _flushPending(currentMs);

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
      for (final item in track) {
        item.dispose();
      }
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

  void _flushPending(int currentMs) {
    if (_pending.isEmpty) return;
    final retry = List<DanmakuComment>.from(_pending);
    _pending.clear();
    for (final comment in retry) {
      // 过时太久的不再补发，避免弹幕和画面对不上
      if (currentMs - comment.fireAtMs > _maxLateMs) continue;
      if (!_tryAddToTrack(comment.content)) {
        _pending.add(comment);
      }
    }
    if (_pending.length > 20) {
      _pending.removeRange(0, _pending.length - 20);
    }
  }

  bool _tryAddToTrack(String content) {
    final screenWidth = MediaQuery.of(context).size.width;
    final textScaler = MediaQuery.textScalerOf(context);
    TextPainter make(String text, TextStyle style) => TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        )..layout();
    final fillStyle = TextStyle(
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w500,
      color: Colors.white,
    );
    final strokeStyle = TextStyle(
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w500,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0x8F000000),
    );
    // 表情比字略大一点（约 1.25 倍字号），和红果一样嵌在文字行里
    final emojiSize = textScaler.scale(widget.fontSize) * 1.25;
    final pieces = <_Piece>[];
    for (final run in splitDanmakuEmoji(content)) {
      final image = run.isEmoji ? _EmojiImages.cache[run.asset] : null;
      if (image != null) {
        pieces.add(_Piece.image(image, emojiSize + 2));
      } else {
        final text = run.isEmoji ? run.fallback! : run.text!;
        pieces.add(_Piece.text(make(text, fillStyle), make(text, strokeStyle)));
      }
    }
    if (pieces.isEmpty) return true;
    final textWidth = pieces.fold<double>(0, (w, p) => w + p.width);
    // 红果：每条弹幕从右边进入到完全离开左边用同样的时长，长弹幕走得快一些
    final totalDistance = screenWidth + textWidth;
    final baseSpeed = totalDistance / widget.durationMs;
    final speed = baseSpeed * (0.98 + _random.nextDouble() * 0.04);

    for (int i = 0; i < _tracks.length; i++) {
      if (_canInsert(i, screenWidth, speed)) {
        _tracks[i].add(
          _DanmakuItem(
            x: screenWidth,
            width: textWidth,
            speed: speed,
            pieces: pieces,
          ),
        );
        return true;
      }
    }
    for (final p in pieces) {
      p.dispose();
    }
    return false;
  }

  /// 这一行能否从右边放入新弹幕：前一条的尾巴已离开右边缘至少 48dp，
  /// 并且新弹幕（若更快）在前一条离屏之前追不上它。
  bool _canInsert(int trackIndex, double screenWidth, double speed) {
    if (_tracks[trackIndex].isEmpty) return true;
    final last = _tracks[trackIndex].last;
    final tail = last.x + last.width;
    final room = screenWidth - tail - _gap;
    if (room < 0) return false;
    if (speed <= last.speed) return true;
    final lastExitMs = tail / last.speed;
    return room >= (speed - last.speed) * lastExitMs;
  }

  double? _cachedTextHeight;
  double? _cachedFor;

  /// 当前字号下一行文字的实际高度（表情图按它垂直居中）
  double _textHeight(BuildContext context) {
    final scaled = MediaQuery.textScalerOf(context).scale(widget.fontSize);
    if (_cachedFor == scaled && _cachedTextHeight != null) {
      return _cachedTextHeight!;
    }
    final tp = TextPainter(
      text: TextSpan(
        text: '国',
        style: TextStyle(fontSize: scaled, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _cachedFor = scaled;
    _cachedTextHeight = tp.height;
    tp.dispose();
    return _cachedTextHeight!;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    // 行高 = 字高 + 4dp 行间距（红果 DanmakuTextSize.verticalMargin）
    final trackHeight =
        MediaQuery.textScalerOf(context).scale(widget.fontSize) * 1.4 + 4;
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
              // 文字行高（用于让表情图和文字垂直居中对齐）
              textHeight: _textHeight(context),
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
  final double textHeight;
  final Paint _imagePaint = Paint()..filterQuality = FilterQuality.medium;

  _DanmakuPainter({
    required this.tracks,
    required this.trackHeight,
    required this.topOffset,
    required this.textHeight,
    required _RepaintNotifier repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < tracks.length; i++) {
      final y = topOffset + i * trackHeight;
      for (final item in tracks[i]) {
        var dx = item.x;
        for (final piece in item.pieces) {
          final image = piece.image;
          if (image != null) {
            final size = piece.width - 2;
            final top = y + (textHeight - size) / 2;
            canvas.drawImageRect(
              image,
              Rect.fromLTWH(
                  0, 0, image.width.toDouble(), image.height.toDouble()),
              Rect.fromLTWH(dx + 1, top, size, size),
              _imagePaint,
            );
          } else {
            final offset = Offset(dx, y);
            piece.stroke!.paint(canvas, offset);
            piece.fill!.paint(canvas, offset);
          }
          dx += piece.width;
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => false;
}
