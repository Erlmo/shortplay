import 'dart:math' as math;
import 'dart:typed_data';

/// Parameters of libttmplayer's PID selector (73970, ARM64 0x11be9c).
/// These are constructor defaults, not proof that a particular feed enables PID.
class NativeAbrPidConfig {
  const NativeAbrPidConfig({
    this.targetBufferSeconds = 2.5,
    this.safeBufferRatio = 0.75,
    this.kp = 0.5,
    this.ki = 0.4,
    this.kd = 0.1,
    this.switchCount = 4,
    this.backoffEnabled = true,
    this.switchLimit = 0,
    this.downBufferMilliseconds = 0,
    this.maximumBandwidthFactor = 0.9,
  });

  final double targetBufferSeconds, safeBufferRatio, kp, ki, kd;
  final int switchCount, switchLimit, downBufferMilliseconds;
  final bool backoffEnabled;
  final double maximumBandwidthFactor;
}

/// A measured snapshot at the selector boundary, after the native sample update.
/// Bandwidths and renditions must share units; elapsed time is since source open.
/// Cache bytes, wall-clock playback time and unknown buffers are not samples.
class NativeAbrSnapshot {
  const NativeAbrSnapshot({
    required this.elapsedMilliseconds,
    required this.bufferSeconds,
    required this.predictedBandwidth,
    required this.bandwidthRecords,
    required this.bufferRecords,
    this.opened = true,
    this.enabled = true,
    this.peakBandwidth = 0,
    this.segmentMilliseconds = 0,
    this.bufferState = 0,
  });

  final int elapsedMilliseconds, predictedBandwidth, peakBandwidth;
  final int segmentMilliseconds, bufferState;
  final double bufferSeconds;
  final List<int> bandwidthRecords;
  final List<double> bufferRecords;
  final bool opened, enabled;

  bool get isValid =>
      elapsedMilliseconds >= 0 &&
      bufferSeconds.isFinite &&
      bufferSeconds >= 0 &&
      predictedBandwidth > 0 &&
      peakBandwidth >= 0 &&
      segmentMilliseconds >= 0 &&
      bandwidthRecords.every((value) => value > 0) &&
      bufferRecords.every((value) => value.isFinite && value >= 0);
}

double _float32(double value) =>
    (ByteData(4)..setFloat32(0, value)).getFloat32(0);

/// ARM64 0x11d9a8. The harmonic branch does NOT apply the arithmetic factor.
int nativeAbrHarmonicBandwidth(List<int> records) {
  if (records.isEmpty) return 0;
  var inverse = 0.0;
  for (final value in records) {
    inverse += 1 / math.max(1, value);
  }
  return (records.length / inverse).truncate();
}

/// ARM64 0x11d88c uses the peak held at +0x318, not the latest transfer rate.
int nativeAbrUpdatedBandwidth(int count, int predicted, int peak) {
  if (count == 0 || predicted == 0 || peak == 0) return predicted;
  final inverse = count / predicted + 1 / peak;
  return inverse.abs() < 0.00001
      ? predicted
      : ((count + 1) / inverse).truncate();
}

/// Independent reconstruction of the native PID decision, not its JNI library.
/// Inputs are explicit: no fabricated speed predictor or seamless MP4 support.
class NativeAbrPidSelector {
  NativeAbrPidSelector({this.config = const NativeAbrPidConfig()}) {
    if (![
          config.targetBufferSeconds,
          config.safeBufferRatio,
          config.kp,
          config.ki,
          config.kd,
          config.maximumBandwidthFactor,
        ].every((value) => value.isFinite) ||
        config.targetBufferSeconds <= 0 ||
        config.safeBufferRatio <= 0 ||
        config.maximumBandwidthFactor <= 0 ||
        config.switchCount < 1 ||
        config.switchLimit < 0 ||
        config.downBufferMilliseconds < 0) {
      throw ArgumentError('无效的原生ABR参数');
    }
  }
  final NativeAbrPidConfig config;
  int upCount = 0;
  int downCount = 0;
  int backoff = 1;
  int switchCount = 0;
  int _previousBufferState = -1;
  int _lastElapsed = 0;
  bool _recovered = false;

  void reset() {
    upCount = downCount = switchCount = _lastElapsed = 0;
    backoff = 1;
    _previousBufferState = -1;
    _recovered = false;
  }

  int select({
    required List<int> bitrates,
    required int current,
    required NativeAbrSnapshot sample,
  }) {
    if (bitrates.isEmpty ||
        bitrates.any((value) => value <= 0) ||
        !sample.isValid ||
        !sample.opened ||
        sample.elapsedMilliseconds < 4000 ||
        (config.switchLimit > 0 && switchCount >= config.switchLimit)) {
      return current;
    }
    // Native media-info setup sorts the available bitrate vector.
    final levels = bitrates.toSet().toList()..sort();
    if (_previousBufferState == 0 && sample.bufferState == 1) {
      _recovered = true;
      backoff = (backoff * 2).clamp(1, 8);
    }
    _previousBufferState = sample.bufferState;
    var selected = current;
    if (sample.enabled) {
      if (sample.bufferSeconds <
          config.targetBufferSeconds * _float32(config.safeBufferRatio)) {
        upCount = 0;
        final budget = nativeAbrUpdatedBandwidth(sample.bandwidthRecords.length,
            sample.predictedBandwidth, sample.peakBandwidth);
        var candidate = levels.first;
        for (final value in levels.reversed) {
          if (budget > value) {
            candidate = value;
            break;
          }
        }
        if (candidate < current) {
          final previous = downCount++;
          if (sample.bufferSeconds * 1000 >
                  math.max(sample.segmentMilliseconds,
                      config.downBufferMilliseconds) ||
              _recovered ||
              previous >= config.switchCount) {
            downCount = 0;
            selected = candidate;
          }
        } else {
          downCount = 0;
        }
      } else {
        final p = (sample.bufferSeconds - config.targetBufferSeconds)
            .clamp(-0.5, 0.5);
        var i = 0.0;
        if (sample.bufferRecords.length > 1) {
          for (final buffer in sample.bufferRecords) {
            i += buffer - config.targetBufferSeconds;
          }
          i /= sample.bufferRecords.length;
        }
        final elapsed =
            _float32((sample.elapsedMilliseconds - _lastElapsed) / 1000);
        var d = 0.0;
        if (elapsed > 0 && sample.bufferRecords.length >= 2) {
          final buffers = sample.bufferRecords;
          d = _float32((buffers.last - buffers[buffers.length - 2]) / elapsed);
        }
        final predicted = ((1 +
                    config.kp * p +
                    config.ki * i.clamp(-0.5, 0.5) +
                    config.kd * d) *
                sample.predictedBandwidth)
            .truncate();
        downCount = 0;
        if (predicted > current) {
          upCount++;
          final threshold =
              config.switchCount * (config.backoffEnabled ? backoff : 1);
          if (upCount >= threshold) {
            final maximum = sample.bandwidthRecords.fold<int>(0, math.max);
            var candidate = levels.first;
            for (final value in levels.reversed) {
              if (maximum * config.maximumBandwidthFactor >= value) {
                candidate = value;
                break;
              }
            }
            if (sample.bufferSeconds * 1000 > sample.segmentMilliseconds &&
                candidate > current) {
              selected = candidate;
              upCount = 0;
            }
          }
        } else {
          upCount = 0;
        }
      }
    }
    // ARM64 0x11c360: strictly closer wins; ties retain the first sorted level.
    var nearest = levels.first;
    for (final level in levels.skip(1)) {
      if ((selected - level).abs() < (selected - nearest).abs()) {
        nearest = level;
      }
    }
    _lastElapsed = sample.elapsedMilliseconds;
    if (nearest != current) switchCount++;
    return nearest;
  }
}
