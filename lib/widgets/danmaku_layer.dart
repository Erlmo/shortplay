import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

/// 一条弹幕：出现时把描边文字和表情一次性画成一张图片，之后每帧只移动这张图片，
/// 不再逐帧重新渲染描边文字（描边文字在 GPU 上很耗时，是播放时发热的主要来源之一）。
class _DanmakuItem {
  double x;
  final double width;
  final ui.Image image;

  /// 图片左上角相对「文字左上角」的偏移（四周留了描边余量，表情可能比文字高）。
  final Offset imageOffset;
  final double pixelRatio;

  _DanmakuItem({
    required this.x,
    required this.width,
    required this.image,
    required this.imageOffset,
    required this.pixelRatio,
  });

  void dispose() => image.dispose();
}

/// 53 个弹幕表情（assets/danmaku_emoji）的解码图片，全局只加载一次。
class _EmojiImages {
  static final Map<String, ui.Image> cache = {};
  static Future<void>? _loading;
  static bool loaded = false;

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
    loaded = true;
  }
}

/// 红果 APK 静态默认 Meteor 普通滚动路径：媒体时间入队，逐帧移动。
/// 分批更新保留在屏/待排项；缓冲溢出才淘汰过期或低权重普通项。
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

class _DanmakuLayerState extends State<DanmakuLayer> {
  final List<List<_DanmakuItem>> _tracks = [];
  final Map<String, _DanmakuItem> _items = {};
  final DanmakuMediaClock _clock = DanmakuMediaClock();
  final _repaintNotifier = _RepaintNotifier();

  /// 弹幕位置按真实流逝时间计算；刷新由定时器驱动，每秒约 30 次（和多数短剧的视频帧率一致），
  /// 不再像逐帧计时器那样每秒 60 次，开着弹幕时界面重绘和系统合成都少一半。
  final Stopwatch _stopwatch = Stopwatch()..start();
  Timer? _frameTimer;
  static const _frameInterval = Duration(milliseconds: 33);
  DanmakuTimeline? _timeline;
  String? _layoutSignature;
  List<(String, String, int, int, bool)> _commentSnapshot = [];
  int _dataGeneration = 0;
  int _sourceGeneration = -1;
  bool _resetTimeline = false;
  Duration _lastTickElapsed = Duration.zero;
  bool _emojiReady = _EmojiImages.loaded;

  @override
  void initState() {
    super.initState();
    unawaited(_EmojiImages.load().then((_) {
      if (!mounted) return;
      setState(() => _emojiReady = true);
    }));
    _syncTicker();
  }

  /// 只有播放中且弹幕可见时才定时刷新。暂停或隐藏时停掉定时器，暂停期间界面不再重绘。
  void _syncTicker() {
    if (widget.isPlaying && widget.visible) {
      _frameTimer ??=
          Timer.periodic(_frameInterval, (_) => _onTick(_stopwatch.elapsed));
    } else {
      _frameTimer?.cancel();
      _frameTimer = null;
    }
  }

  /// 暂停时数据或进度变了（换集、拖动进度、开关弹幕），在这一帧构建完后补刷一次。
  void _requestSingleTick() {
    if (_frameTimer != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onTick(_stopwatch.elapsed);
    });
  }

  @override
  void didUpdateWidget(DanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameComments()) {
      _dataGeneration++;
    }
    if (oldWidget.seekGeneration != widget.seekGeneration) {
      _resetTimeline = true;
    }
    if (oldWidget.seekGeneration != widget.seekGeneration ||
        oldWidget.playbackSpeed != widget.playbackSpeed ||
        oldWidget.isPlaying != widget.isPlaying) {
      _clock.reset();
    }
    _syncTicker();
    if (!_sameComments() ||
        oldWidget.seekGeneration != widget.seekGeneration ||
        oldWidget.visible != widget.visible) {
      _requestSingleTick();
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
    _frameTimer?.cancel();
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
    _lastTickElapsed = elapsed;
    final timeline = _timeline;
    if (timeline == null) return;
    final position = _clock.read(
      positionMs: widget.getPositionMs(),
      elapsed: elapsed,
      isPlaying: widget.isPlaying,
      playbackSpeed: widget.playbackSpeed,
    );
    timeline.tick(
      positionMs: position.floor(),
      elapsed: elapsed,
      isPlaying: widget.isPlaying,
      playbackSpeed: widget.playbackSpeed,
    );
    for (final track in _tracks) {
      track.clear();
    }
    if (widget.visible) {
      for (final placement in timeline.placements) {
        final item = _items[placement.cue.id];
        if (item == null) continue;
        item.x = placement.x;
        _tracks[placement.track].add(item);
      }
    }
    _repaintNotifier.notify();
  }

  void _configure(Size size, double trackHeight) {
    // 字形资源就绪后再首次入队，避免图片解码完成时清掉在屏轨道。
    if (!_emojiReady) return;
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
    final signature = '${size.width}:$tracks:$duration:$scale:$pixelRatio';
    final geometryChanged = _layoutSignature != signature;
    if (geometryChanged) {
      _layoutSignature = signature;
      _disposeItems();
      for (var i = 0; i < tracks; i++) {
        _tracks.add([]);
      }
      _timeline = DanmakuTimeline(
        viewportWidth: size.width,
        trackCount: tracks,
        durationMs: duration,
      );
    }
    if (!geometryChanged &&
        !_resetTimeline &&
        _sourceGeneration == _dataGeneration) {
      return;
    }
    _sourceGeneration = _dataGeneration;
    _commentSnapshot = widget.comments
        .map((comment) => (
              comment.id,
              comment.content,
              comment.fireAtMs,
              comment.showBoost,
              comment.forceInsert,
            ))
        .toList();
    final cues = <DanmakuCue>[];
    final known = <String>{};
    for (var index = 0; index < widget.comments.length; index++) {
      final comment = widget.comments[index];
      final id = comment.id.isEmpty
          ? 'missing:${comment.fireAtMs}:${comment.content}:$index'
          : comment.id;
      if (!known.add(id)) continue;
      // 普通追加只测量新项，不销毁当前轨道所引用的文字/表情。
      final item = _items.putIfAbsent(
          id, () => _measure(comment.content.replaceAll('\n', ' ')));
      if (item.width <= 0) continue;
      cues.add(DanmakuCue(
        id: id,
        atMs: comment.fireAtMs,
        width: item.width,
        weight: comment.showBoost.toDouble(),
        forceInsert: comment.forceInsert,
      ));
    }
    final position = _clock.read(
      positionMs: widget.getPositionMs(),
      elapsed: _lastTickElapsed,
      isPlaying: widget.isPlaying,
      playbackSpeed: widget.playbackSpeed,
    );
    _timeline!
        .setSource(cues, positionMs: position.floor(), seek: _resetTimeline);
    if (_resetTimeline) {
      for (final track in _tracks) {
        track.clear();
      }
    }
    _resetTimeline = false;
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
    final width = pieces.fold<double>(0, (sum, piece) => sum + piece.width);
    final item = _rasterize(pieces, width, emojiSize, pixelRatio);
    for (final piece in pieces) {
      piece.dispose();
    }
    return item;
  }

  /// 把一条弹幕的各段（描边文字、白字、表情）画到一张图片上，只做一次。
  _DanmakuItem _rasterize(
      List<_Piece> pieces, double width, double emojiSize, double pixelRatio) {
    final textHeight = _textHeight(context);
    // 描边会超出字形约 1～2 个点，四周留出余量；表情可能比文字高，整体按较高者放。
    const pad = 3.0;
    final contentHeight = emojiSize > textHeight ? emojiSize : textHeight;
    final textTop = pad + (contentHeight - textHeight) / 2;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(pixelRatio);
    final imagePaint = Paint()..filterQuality = FilterQuality.medium;
    var dx = pad;
    for (final piece in pieces) {
      final image = piece.image;
      if (image != null) {
        final top = textTop + (textHeight - piece.width) / 2;
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(dx, top, piece.width, piece.width),
          imagePaint,
        );
      } else {
        final offset = Offset(dx, textTop);
        piece.stroke!.paint(canvas, offset);
        piece.fill!.paint(canvas, offset);
      }
      dx += piece.width;
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      ((width + pad * 2) * pixelRatio).ceil().clamp(1, 1 << 14),
      ((contentHeight + pad * 2) * pixelRatio).ceil(),
    );
    picture.dispose();
    return _DanmakuItem(
      x: 0,
      width: width,
      image: image,
      imageOffset: Offset(-pad, -textTop),
      pixelRatio: pixelRatio,
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
        final image = item.image;
        final src = Rect.fromLTWH(
            0, 0, image.width.toDouble(), image.height.toDouble());
        final dst = Rect.fromLTWH(
          item.x + item.imageOffset.dx,
          y + item.imageOffset.dy,
          image.width / item.pixelRatio,
          image.height / item.pixelRatio,
        );
        canvas.drawImageRect(image, src, dst, _imagePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => false;
}
