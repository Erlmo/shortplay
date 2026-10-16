import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/danmaku.dart';
import '../utils/emoji_map.dart';
import 'danmaku_timeline.dart';

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
  final List<_Piece> pieces;

  _DanmakuItem({
    required this.x,
    required this.width,
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

/// 红果 APK 静态默认 Meteor 普通滚动路径，采用媒体时间排版、
/// 缓冲溢出时清理超过 4000 ms 的普通项，并防同轨追尾。
/// 不再按帧区间触发后永久跳过迟到数据。
/// APK 宿主静态默认竖屏 2 行，远程实验/用户配置可覆盖；横屏默认上 1/4 区域。
/// 这不是互动/特殊弹幕或远程实验配置的一比一复刻。
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
    this.maxTracks,
    this.durationMs,
    this.topOffset,
    this.seekGeneration = 0,
  });

  final List<DanmakuComment> comments;
  final int Function() getPositionMs;
  final bool isPlaying;
  final bool visible;
  final double playbackSpeed;
  final double fontSize;
  final double opacity;
  final int? maxTracks;
  final int? durationMs;
  final double? topOffset;
  final int seekGeneration;

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _DanmakuLayerState extends State<DanmakuLayer>
    with SingleTickerProviderStateMixin {
  final List<List<_DanmakuItem>> _tracks = [];
  final Map<String, _DanmakuItem> _items = {};
  final DanmakuMediaClock _clock = DanmakuMediaClock();
  final _repaintNotifier = _RepaintNotifier();
  late final Ticker _ticker;
  DanmakuTimeline? _timeline;
  String? _layoutSignature;
  double _viewportWidth = 0;
  List<(String, String, int, int, bool)> _commentSnapshot = [];
  int _dataGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_EmojiImages.load().then((_) {
      if (!mounted) return;
      setState(() => _layoutSignature = null);
    }));
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(DanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameComments()) {
      _dataGeneration++;
      _layoutSignature = null;
    }
    if (oldWidget.seekGeneration != widget.seekGeneration ||
        oldWidget.playbackSpeed != widget.playbackSpeed ||
        oldWidget.isPlaying != widget.isPlaying) {
      _clock.reset();
    }
  }

  bool _sameComments() {
    if (widget.comments.length != _commentSnapshot.length) return false;
    for (var i = 0; i < widget.comments.length; i++) {
      final comment = widget.comments[i];
      if (_commentSnapshot[i] !=
          (
            comment.id,
            comment.content,
            comment.fireAtMs,
            comment.showBoost,
            comment.forceInsert
          )) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _disposeItems();
    _repaintNotifier.dispose();
    super.dispose();
  }

  void _disposeItems() {
    for (final item in _items.values) {
      item.dispose();
    }
    _items.clear();
    _tracks.clear();
  }

  void _onTick(Duration elapsed) {
    final timeline = _timeline;
    if (timeline == null) return;
    final position = _clock.read(
      positionMs: widget.getPositionMs(),
      elapsed: elapsed,
      isPlaying: widget.isPlaying,
      playbackSpeed: widget.playbackSpeed,
    );
    for (final track in _tracks) {
      track.clear();
    }
    if (widget.visible) {
      for (final placement in timeline.placements) {
        if (!placement.visibleAt(position, _viewportWidth)) continue;
        final item = _items[placement.cue.id];
        if (item == null) continue;
        item.x = placement.xAt(position, _viewportWidth);
        _tracks[placement.track].add(item);
      }
    }
    _repaintNotifier.notify();
  }

  void _configure(Size size, double trackHeight) {
    final landscape = size.width > size.height;
    // nl2.e.a() 使用 getRealMetrics 的屏幕高度，而非弹幕容器高度。
    final view = View.of(context);
    final screenHeight = view.physicalSize.height / view.devicePixelRatio;
    final count = widget.maxTracks ??
        (landscape ? (screenHeight * 0.25 / trackHeight).floor() : 2);
    final tracks = count.clamp(1, 100);
    final duration = widget.durationMs ?? (landscape ? 12000 : 10000);
    final scale = MediaQuery.textScalerOf(context).scale(widget.fontSize);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final signature =
        '${size.width}:$tracks:$duration:$scale:$pixelRatio:$_dataGeneration';
    if (_layoutSignature == signature) return;
    _layoutSignature = signature;
    _commentSnapshot = widget.comments
        .map((comment) => (
              comment.id,
              comment.content,
              comment.fireAtMs,
              comment.showBoost,
              comment.forceInsert,
            ))
        .toList();
    _viewportWidth = size.width;
    _disposeItems();
    for (var i = 0; i < tracks; i++) {
      _tracks.add([]);
    }
    final cues = <DanmakuCue>[];
    for (var index = 0; index < widget.comments.length; index++) {
      final comment = widget.comments[index];
      // 上游缺失 ID 时仍保留不同条目；顺序作为重复文本的区分依据。
      final id = comment.id.isEmpty
          ? 'missing:${comment.fireAtMs}:${comment.content}:$index'
          : comment.id;
      if (_items.containsKey(id)) continue;
      final item = _measure(comment.content.replaceAll('\n', ' '));
      if (item.width <= 0) {
        item.dispose();
        continue;
      }
      _items[id] = item;
      cues.add(DanmakuCue(
        id: id,
        atMs: comment.fireAtMs,
        width: item.width,
        weight: comment.showBoost.toDouble(),
        forceInsert: comment.forceInsert,
      ));
    }
    _timeline = DanmakuTimeline(
      viewportWidth: size.width,
      trackCount: tracks,
      durationMs: duration,
    )..layout(cues);
  }

  _DanmakuItem _measure(String content) {
    final textScaler = MediaQuery.textScalerOf(context);
    TextPainter make(String text, TextStyle style) => TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        )..layout();
    final fillStyle = TextStyle(
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w400,
      color: Colors.white,
    );
    final strokeStyle = TextStyle(
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w400,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        // Meteor Paint.setStrokeWidth(2.75f) 使用物理像素，非 dp。
        ..strokeWidth = 2.75 / MediaQuery.devicePixelRatioOf(context)
        ..strokeJoin = StrokeJoin.miter
        ..color = const Color(0x8F000000),
    );
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    // VideoDanmakuBaseData.E: 字号 * 0.9；jg2.c.m: 再 * 1.4，
    // 截断到物理像素整数。wh2.d.getSize 不另加左右间距。
    final emojiSize =
        (textScaler.scale(widget.fontSize) * pixelRatio * 0.9 * 1.4).floor() /
            pixelRatio;
    final pieces = <_Piece>[];
    for (final run in splitDanmakuEmoji(content)) {
      final image = run.isEmoji ? _EmojiImages.cache[run.asset] : null;
      if (image != null) {
        pieces.add(_Piece.image(image, emojiSize));
      } else {
        final text = run.isEmoji ? run.fallback! : run.text!;
        pieces.add(_Piece.text(make(text, fillStyle), make(text, strokeStyle)));
      }
    }
    return _DanmakuItem(
      x: 0,
      width: pieces.fold<double>(0, (width, piece) => width + piece.width),
      pieces: pieces,
    );
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
        style: TextStyle(fontSize: scaled, fontWeight: FontWeight.w400),
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
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      // APK 默认字号含上下各 8 dp 内边距，行间距 4 dp。
      final trackHeight = _textHeight(context) + 16 + 4;
      _configure(size, trackHeight);
      final topOffset =
          widget.topOffset ?? MediaQuery.of(context).viewPadding.top + 80;
      return IgnorePointer(
        child: Opacity(
          opacity: widget.visible ? widget.opacity : 0,
          child: RepaintBoundary(
            child: ClipRect(
              child: CustomPaint(
                painter: _DanmakuPainter(
                  tracks: _tracks,
                  trackHeight: trackHeight,
                  topOffset: topOffset,
                  textHeight: _textHeight(context),
                  repaint: _repaintNotifier,
                ),
                size: size,
              ),
            ),
          ),
        ),
      );
    });
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
            final size = piece.width;
            final top = y + (textHeight - size) / 2;
            canvas.drawImageRect(
              image,
              Rect.fromLTWH(
                  0, 0, image.width.toDouble(), image.height.toDouble()),
              Rect.fromLTWH(dx, top, size, size),
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
