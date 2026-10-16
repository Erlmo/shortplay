import 'dart:math' as math;

/// 红果 7.3.9.70 Meteor 普通滚动弹幕的静态证据适配。
/// 证据与未覆盖的业务特效见 build/reverse-hongguo-73970/danmaku/render-findings.md。
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
  const DanmakuPlacement(this.cue, this.track, this.startMs, this.speed);

  final DanmakuCue cue;
  final int track;
  final int startMs;
  final double speed;

  double xAt(double positionMs, double viewportWidth) =>
      viewportWidth - (positionMs - startMs) * speed;

  bool visibleAt(double positionMs, double viewportWidth) =>
      positionMs >= startMs && xAt(positionMs, viewportWidth) + cue.width > 0;
}

/// 采用媒体时间排版，渲染掉帧、暂停、请求晚返回不会改变弹幕的出现时刻。
/// 默认缓冲超过 8 项时清理已等待 4000 ms 的普通项；
/// 未拥堵时不会无条件删除迟到项。16 ms 为 Flutter 排版采样。
/// 特殊置顶/互动/中心停留弹幕不属于本适配器覆盖范围。
class DanmakuTimeline {
  DanmakuTimeline({
    required this.viewportWidth,
    required this.trackCount,
    required this.durationMs,
    this.gap = 48,
  });

  static const stepMs = 16;
  static const maxWaitMs = 4000;
  static const maxPending = 8;
  final double viewportWidth;
  final int trackCount;
  final int durationMs;
  final double gap;
  final List<DanmakuPlacement> placements = [];

  void layout(Iterable<DanmakuCue> source) {
    placements.clear();
    if (!viewportWidth.isFinite ||
        viewportWidth <= 0 ||
        trackCount <= 0 ||
        durationMs <= 0) {
      return;
    }
    final cues = source
        .where((cue) => cue.width.isFinite && cue.width > 0 && cue.atMs >= 0)
        .toList();
    // 稳定排序保证相同时间/权重按接口次序，而非随机抖动。
    final order = <DanmakuCue, int>{
      for (var i = 0; i < cues.length; i++) cues[i]: i,
    };
    cues.sort((a, b) {
      final byTime = a.atMs.compareTo(b.atMs);
      return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
    });
    int compareEviction(DanmakuCue a, DanmakuCue b) {
      var result = a.weight.compareTo(b.weight);
      if (result == 0) result = a.atMs.compareTo(b.atMs);
      return result != 0 ? result : order[a]!.compareTo(order[b]!);
    }

    final last = List<DanmakuPlacement?>.filled(trackCount, null);
    final pending = <DanmakuCue>[];
    var next = 0;
    var time = 0;
    while (next < cues.length || pending.isNotEmpty) {
      if (pending.isEmpty && next < cues.length) {
        time = math.max(time, (cues[next].atMs / stepMs).ceil() * stepMs);
      }
      var received = false;
      while (next < cues.length && cues[next].atMs <= time) {
        pending.add(cues[next++]);
        received = true;
      }
      if (received && pending.length > maxPending) {
        pending.removeWhere(
            (cue) => !cue.forceInsert && time - cue.atMs > maxWaitMs);
      }
      // Meteor 默认关闭 sort_refactor：保持入队顺序，仅溢出时淘汰低权重。
      while (pending.length > maxPending) {
        final removable = pending.where((cue) => !cue.forceInsert);
        if (removable.isEmpty) break;
        final discard =
            removable.reduce((a, b) => compareEviction(a, b) <= 0 ? a : b);
        pending.remove(discard);
      }
      final waiting = <DanmakuCue>[];
      for (final cue in pending) {
        final speed = (viewportWidth + cue.width) / durationMs;
        var placed = false;
        for (var track = 0; track < trackCount; track++) {
          final previous = last[track];
          if (previous != null && !_fits(previous, time, speed)) continue;
          final placement = DanmakuPlacement(cue, track, time, speed);
          placements.add(placement);
          last[track] = placement;
          placed = true;
          break;
        }
        if (!placed) waiting.add(cue);
      }
      pending
        ..clear()
        ..addAll(waiting);
      time += stepMs;
    }
  }

  bool _fits(DanmakuPlacement previous, int time, double speed) {
    final tail =
        previous.xAt(time.toDouble(), viewportWidth) + previous.cue.width;
    if (tail <= 0) return true;
    final room = viewportWidth - tail - gap;
    if (room < 0) return false;
    if (previous.speed >= speed) return true;
    // 后条更快时，校验前条退出屏幕前不会被追上（含最小间距）。
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
