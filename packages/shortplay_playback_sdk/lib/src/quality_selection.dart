import 'dart:math' as math;

import 'first_frame.dart';
import 'native_abr.dart';

class QualityRendition<T> {
  const QualityRendition(this.definition, this.bitrate, this.value);
  final String definition;
  final int bitrate;
  final T value;
}

/// Observed Resolution.ordinal order, deliberately not pixel-height distance.
const _resolutionOrder = [
  '',
  '360p',
  '480p',
  '720p',
  '1080p',
  '4k',
  'hdr',
  'auto',
  '240p',
  '540p',
  '2k',
  '1080p 50fps',
  '2k 50fps',
  '4k 50fps',
  '1080p 60fps',
  '2k 60fps',
  '4k 60fps',
  '1080p 120fps',
  '2k 120fps',
  '4k 120fps',
  '240p hdr',
  '360p hdr',
  '480p hdr',
  '540p hdr',
  '720p hdr',
  '1080p hdr',
  '2k hdr',
  '4k hdr',
  '8k',
  '1080p+',
];

class PlaybackQualitySelector {
  static QualityRendition<T> defaultResolution<T>(
      List<QualityRendition<T>> items, String preferred) {
    if (items.isEmpty) throw StateError('没有可用清晰度');
    final wanted = preferred.trim().toLowerCase();
    final index = _resolutionOrder.indexOf(wanted);
    var best = items.first;
    var distance = _resolutionOrder.length;
    for (final item in items) {
      final name = item.definition.trim().toLowerCase();
      if (name == wanted) return item;
      final ordinal = _resolutionOrder.indexOf(name);
      if (ordinal <= 0 || index <= 0) continue;
      final delta = (ordinal - index).abs();
      if (delta < distance) {
        best = item;
        distance = delta;
      }
    }
    return best;
  }

  /// BestResolution.findByNetLevel uses a target bitrate, not raw network speed.
  /// If none fits, it retains the selected default (does not force the lowest).
  static QualityRendition<T> byTargetBitrate<T>(List<QualityRendition<T>> items,
      double? target, QualityRendition<T> fallback) {
    if (target == null || !target.isFinite || target <= 0) return fallback;
    var best = fallback;
    var difference = double.infinity;
    for (final item in items) {
      final delta = target - item.bitrate;
      if (item.bitrate > 0 && delta >= 0 && delta < difference) {
        best = item;
        difference = delta;
      }
    }
    return best;
  }

  /// SpeedShiftSelector.findMaxBitrate differs from findByNetLevel: if all
  /// candidates exceed its configured budget, choose the lowest bitrate.
  static QualityRendition<T> maxUnderBudget<T>(
      List<QualityRendition<T>> items, double target) {
    if (items.isEmpty) throw StateError('没有可用清晰度');
    var best = items.first;
    for (final item in items.skip(1)) {
      if (best.bitrate > target) {
        if (item.bitrate < best.bitrate) best = item;
      } else if (item.bitrate <= target && item.bitrate >= best.bitrate) {
        best = item;
      }
    }
    return best;
  }
}

/// Exact Java arithmetic requires caller-supplied configuration. No invented
/// coefficients, buffer thresholds or native bandwidth-predictor replacement.
class PolynomialBitrateConfig {
  const PolynomialBitrateConfig(this.a, this.b, this.c, this.d, this.minimum);
  final double a, b, c, d, minimum;
  double? target(double speed) {
    if (!speed.isFinite || speed <= 0) return null;
    final value = a * speed * speed * speed + b * speed * speed + c * speed + d;
    return value.isFinite ? math.max(value, minimum) : null;
  }
}

class BandwidthBitrateBand {
  const BandwidthBitrateBand(this.speed, this.bitrate);
  final double speed, bitrate;
}

double? configuredBandwidthTarget(
    double speed, List<BandwidthBitrateBand> bands) {
  if (!speed.isFinite || speed <= 0 || bands.isEmpty) return null;
  // Preserve configured order, as the Java selector does; do not sort it.
  return bands
      .firstWhere((band) => speed <= band.speed, orElse: () => bands.last)
      .bitrate;
}

/// Host adapter for explicit, measured native-style PID snapshots. It only
/// recommends a complete rendition; switching remains the host's transaction.
/// In particular, a recommendation does not imply seamless progressive MP4.
class NativeAbrQualityPolicy {
  NativeAbrQualityPolicy(
      {NativeAbrPidConfig config = const NativeAbrPidConfig()})
      : selector = NativeAbrPidSelector(config: config);

  final NativeAbrPidSelector selector;
  String? _sourceId;
  int? _lastSampleMilliseconds;

  void reset() {
    selector.reset();
    _sourceId = null;
    _lastSampleMilliseconds = null;
  }

  QualityRendition<T> recommend<T>({
    required String sourceId,
    required List<QualityRendition<T>> items,
    required QualityRendition<T> current,
    required NativeAbrSnapshot? sample,
    bool manual = false,
  }) {
    if (_sourceId != sourceId || manual) {
      reset();
      _sourceId = sourceId;
    }
    if (manual ||
        sourceId.isEmpty ||
        sample == null ||
        !sample.isValid ||
        current.bitrate <= 0 ||
        !items.contains(current) ||
        items.any((item) => item.bitrate <= 0) ||
        items.length < 2) {
      return current;
    }
    // Host ownership guard: polling the same snapshot twice must not create
    // two observations. A seek/discontinuity needs an explicit reset.
    if (_lastSampleMilliseconds != null &&
        sample.elapsedMilliseconds <= _lastSampleMilliseconds!) {
      return current;
    }
    _lastSampleMilliseconds = sample.elapsedMilliseconds;
    final bitrate = selector.select(
      bitrates: items.map((item) => item.bitrate).toList(),
      current: current.bitrate,
      sample: sample,
    );
    if (bitrate == current.bitrate) return current;
    return items.firstWhere((item) => item.bitrate == bitrate,
        orElse: () => current);
  }
}

class QualitySwitchTicket {
  QualitySwitchTicket._(this.definition, this.position, this.wantsPlaying);
  final String definition;
  final Duration position;
  bool wantsPlaying;
  final cancellation = PlaybackCancellation();
}

/// Repeated requests replace the target but retain the first captured progress.
/// Ownership remains with the host; completion must mean a real target frame.
class QualitySwitchCoordinator {
  QualitySwitchTicket? _pending;
  QualitySwitchTicket? get pending => _pending;
  QualitySwitchTicket? begin(String definition,
      {required Duration position, required bool wantsPlaying}) {
    final name = definition.trim().toLowerCase();
    if (_pending?.definition == name) return null;
    final old = _pending;
    old?.cancellation.cancel();
    return _pending = QualitySwitchTicket._(
        name, old?.position ?? position, old?.wantsPlaying ?? wantsPlaying);
  }

  bool isCurrent(QualitySwitchTicket ticket) =>
      identical(_pending, ticket) && !ticket.cancellation.isCancelled;
  void finish(QualitySwitchTicket ticket) {
    if (identical(_pending, ticket)) _pending = null;
  }

  void cancel() {
    _pending?.cancellation.cancel();
    _pending = null;
  }
}
