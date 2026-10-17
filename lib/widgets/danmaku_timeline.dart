import 'dart:math' as math;

/// 红果 7.3.9.70 Meteor 普通滚动弹幕的静态证据适配。
/// 调度证据：build/reverse-hongguo-73970/danmaku/queue-handoff-reaudit/。
class DanmakuCue {
  const DanmakuCue({
    required this.id,
    required this.atMs,
    required this.width,
    this.weight = 0,
    this.forceInsert = false,
  });

  final String id;
  final int atMs;
  final double width;
  final double weight;
  final bool forceInsert;
}

class DanmakuPlacement {
  DanmakuPlacement(this.cue, this.track, this.startMs, this.speed, this.x);

  final DanmakuCue cue;
  final int track;
  final int startMs;
  // 未乘播放倍速的像素/毫秒；倍速变化时保留位置，仅调整后续运动。
  final double speed;
  double x;
}

/// 媒体时间只决定入队、淘汰；已上屏项按真实渲染帧移动。
/// 对应 uu7.b.n -> BaseRenderLayer.j/a -> DragonScrollLine.e/a。
/// 普通数据更新重定位 provider，保留正在滚动和待排的项；只有 seek 清轨。
/// 未开启 APK 默认关闭的 seekOpt 回溯/特殊弹幕实验。
class DanmakuTimeline {
  DanmakuTimeline({
    required this.viewportWidth,
    required this.trackCount,
    required this.durationMs,
    this.gap = 48,
  });

  static const maxFrameMs = 16;
  static const maxWaitMs = 4000;
  static const maxPending = 8;
  final double viewportWidth;
  final int trackCount;
  final int durationMs;
  final double gap;

  List<DanmakuCue> _source = const [];
  final List<DanmakuCue> _pending = [];
  final List<DanmakuPlacement> placements = [];
  final Set<String> _delivered = {};
  final Map<String, int> _order = {};
  int _next = 0;
  Duration? _lastFrame;

  bool get _valid =>
      viewportWidth.isFinite &&
      viewportWidth > 0 &&
      trackCount > 0 &&
      durationMs > 0;

  /// 对应 controller.l(current,list) / provider.d + e：更新完整数据和读取游标，
  /// 不从零模拟历史轨道，也不把迟到旧项塞进普通8条缓冲去挤掉在屏项。
  void setSource(Iterable<DanmakuCue> source,
      {required int positionMs, bool seek = false}) {
    if (seek) {
      placements.clear();
      _pending.clear();
      _delivered.clear();
      _lastFrame = null;
    }
    _source = source
        .where((cue) => cue.width.isFinite && cue.width > 0 && cue.atMs >= 0)
        .toList();
    _order.clear();
    for (var i = 0; i < _source.length; i++) {
      _order[_source[i].id] = i;
    }
    _source.sort((a, b) {
      final result = a.atMs.compareTo(b.atMs);
      return result != 0 ? result : _order[a.id]!.compareTo(_order[b.id]!);
    });
    var low = 0;
    var high = _source.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_source[mid].atMs < positionMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    _next = low;
  }

  void tick({
    required int positionMs,
    required Duration elapsed,
    required bool isPlaying,
    double playbackSpeed = 1,
  }) {
    if (!_valid) return;
    final previousFrame = _lastFrame;
    // DragonScrollLine 构造 t=16；后续帧 min(now-last,16)。Flutter 使用单调时钟。
    final deltaMs = previousFrame == null
        ? maxFrameMs.toDouble()
        : ((elapsed - previousFrame).inMicroseconds / 1000)
            .clamp(0.0, maxFrameMs.toDouble());
    _lastFrame = elapsed;

    var received = false;
    while (_next < _source.length && _source[_next].atMs <= positionMs) {
      final cue = _source[_next++];
      if (!_delivered.add(cue.id)) continue;
      _pending.add(cue);
      received = true;
    }
    // BaseRenderLayer.j：仅有新项入队且普通缓冲溢出时清过期，再淘汰低权重。
    if (received && _pending.length > maxPending) {
      _pending.removeWhere(
          (cue) => !cue.forceInsert && positionMs - cue.atMs > maxWaitMs);
      while (_pending.length > maxPending) {
        DanmakuCue? discard;
        for (final cue in _pending) {
          if (cue.forceInsert) continue;
          if (discard == null || _compareEviction(cue, discard) < 0) {
            discard = cue;
          }
        }
        if (discard == null) break;
        _pending.remove(discard);
      }
    }

    // 重试待排项在运动之前，成功入轨才设置实际入场时刻和右侧起点。
    final last = List<DanmakuPlacement?>.filled(trackCount, null);
    for (final placement in placements) {
      last[placement.track] = placement;
    }
    _pending.removeWhere((cue) {
      final speed = (viewportWidth + cue.width) / durationMs;
      for (var track = 0; track < trackCount; track++) {
        final previous = last[track];
        if (previous != null && !_fits(previous, speed)) continue;
        final placement =
            DanmakuPlacement(cue, track, positionMs, speed, viewportWidth);
        placements.add(placement);
        last[track] = placement;
        return true;
      }
      return false;
    });

    // 不用 position-start 计算坐标：媒体锚点更新、批次追加和掉帧不会清空屏幕。
    if (isPlaying) {
      for (final placement in placements) {
        placement.x -= placement.speed * playbackSpeed * deltaMs;
      }
    }
    placements
        .removeWhere((placement) => placement.x + placement.cue.width < 0);
  }

  int _compareEviction(DanmakuCue a, DanmakuCue b) {
    var result = a.weight.compareTo(b.weight);
    if (result == 0) result = a.atMs.compareTo(b.atMs);
    return result != 0
        ? result
        : (_order[a.id] ?? 0).compareTo(_order[b.id] ?? 0);
  }

  bool _fits(DanmakuPlacement previous, double speed) {
    final tail = previous.x + previous.cue.width;
    final room = viewportWidth - tail - gap;
    if (room < 0) return false;
    if (previous.speed >= speed) return true;
    return room >= (speed - previous.speed) * (tail / previous.speed);
  }
}

/// 对应 APK uu7.b.a()：从最近的媒体时间锚点按经过时间和倍速推进，
/// pause 时冻结。没有附加原实现不存在的固定插值上限。
class DanmakuMediaClock {
  int? _sample;
  Duration _sampleAt = Duration.zero;
  double _last = 0;

  void reset() {
    _sample = null;
    _last = 0;
  }

  double read({
    required int positionMs,
    required Duration elapsed,
    required bool isPlaying,
    required double playbackSpeed,
  }) {
    if (_sample != positionMs || !isPlaying) {
      _sample = positionMs;
      _sampleAt = elapsed;
      _last = positionMs.toDouble();
    }
    if (isPlaying) {
      final since = (elapsed - _sampleAt).inMicroseconds / 1000;
      _last = positionMs + math.max(0, since) * playbackSpeed;
    }
    return _last;
  }
}
