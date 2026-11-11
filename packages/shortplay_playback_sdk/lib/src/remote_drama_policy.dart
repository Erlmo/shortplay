import 'dart:math' as math;

/// A complete rendition's canonical Resolution label and bitrate in bits/s.
/// Ownership of its URL, codec and key remains with the host's model.
class RemoteDramaRendition {
  const RemoteDramaRendition(this.definition, this.bitrate);
  final String definition;
  final int bitrate;
}

class RemoteDramaSpeedCondition {
  const RemoteDramaSpeedCondition({
    required this.networkSpeed,
    required this.checkNetType,
  });
  final int networkSpeed;
  final int checkNetType;
}

class RemoteDramaLimitCondition {
  const RemoteDramaLimitCondition({
    required this.isWifi,
    required this.checkNetSpeed,
    this.netSpeed,
  });
  final bool isWifi;
  final bool checkNetSpeed;
  final RemoteDramaSpeedCondition? netSpeed;
}

class RemoteDramaStrategy {
  const RemoteDramaStrategy({
    required this.resolution,
    required this.ignorePeak,
    required this.keepAliveDuration,
    this.limitCondition,
  });
  final String? resolution;
  final bool ignorePeak;
  final int keepAliveDuration;
  final RemoteDramaLimitCondition? limitCondition;
}

class RemoteDramaServerPeak {
  const RemoteDramaServerPeak({
    required this.resolution,
    required this.limitIndex,
    required this.enabled,
  });
  final String? resolution;
  final int limitIndex;
  final bool enabled;
}

class RemoteDramaLocalPeak {
  const RemoteDramaLocalPeak({
    required this.resolutionType,
    required this.resolutionTypeForLow,
    required this.resolutionTypeForMidLow,
  });
  final int resolutionType, resolutionTypeForLow, resolutionTypeForMidLow;
}

class RemoteDramaNetStrategy {
  const RemoteDramaNetStrategy({
    required this.enableNetResolution,
    required this.lowerTimePreloadBestQuality,
    required this.netSpeedType,
    required this.notMatchUseSmallest,
  });
  final bool enableNetResolution, lowerTimePreloadBestQuality;
  final int netSpeedType;
  final bool notMatchUseSmallest;
}

/// Explicit host inputs at qv4.q$a.f's boundary. No JSON schema or native
/// predictor is invented here. A null measurement is unknown, not zero speed.
class RemoteDramaPolicyInput {
  const RemoteDramaPolicyInput({
    required this.hasVideoModel,
    required this.enableServerStrategy,
    required this.enableV713Strategy,
    required this.diggStrategy,
    required this.enableServerPeak,
    required this.useVideoarchPeakPeriod,
    required this.networkStrategy,
    required this.localPeak,
    required this.strategies,
    required this.renditions,
    required this.allowedDefinitions,
    required this.isPreload,
    required this.episodeIndex,
    required this.nowMilliseconds,
    this.serverPeak,
    this.isPeakTime,
    this.isLowDevice,
    this.isMiddleLowDevice,
    this.networkAvailable,
    this.wifiEnabled,
    this.nativePredictorBitsPerSecond,
    this.portraitTargetMegabitsPerSecond,
    this.bitrateFunction,
  });

  final bool hasVideoModel, enableServerStrategy, enableV713Strategy;
  final bool diggStrategy, enableServerPeak, useVideoarchPeakPeriod;
  final RemoteDramaNetStrategy networkStrategy;
  final RemoteDramaLocalPeak localPeak;
  final List<RemoteDramaStrategy>? strategies;
  final List<RemoteDramaRendition?>? renditions;
  final List<String> allowedDefinitions;
  final bool isPreload;
  final int episodeIndex, nowMilliseconds;
  final RemoteDramaServerPeak? serverPeak;
  final bool? isPeakTime, isLowDevice, isMiddleLowDevice;
  final bool? networkAvailable, wifiEnabled;
  final double? nativePredictorBitsPerSecond;
  final double? portraitTargetMegabitsPerSecond;

  /// EngineNetReport.bitRateOptFunction["ShortPlay"], four CSV coefficients.
  final String? bitrateFunction;
}

class RemoteDramaPolicyDecision {
  RemoteDramaPolicyDecision(String? definition, Set<String> missingInputs)
      : definition = missingInputs.isEmpty ? definition : null,
        missingInputs = Set.unmodifiable(missingInputs);
  final String? definition;
  final Set<String> missingInputs;
  bool get isResolved => missingInputs.isEmpty;
}

/// h(String): only uppercase Resolution labels are admitted. Callers that
/// uppercase prefab strings do so explicitly; server peak strings stay raw.
String? parseRemoteDramaResolution(String? value) => switch (value) {
      '360P' || '480P' || '540P' || '720P' || '1080P' => value,
      _ => null,
    };

int _rank(String value) => switch (value) {
      '360P' => 1,
      '480P' => 2,
      '540P' => 3,
      '720P' => 4,
      '1080P' => 5,
      _ => 0,
    };

/// Calendar's local-time, inclusive minute comparison (b65.p0.a).
/// The host supplies already parsed/configured times, including any observed
/// random offsets; this is not a replacement for its remote peak controller.
bool remoteDramaMinuteInRange({
  required int startHour,
  required int startMinute,
  required int endHour,
  required int endMinute,
  required int currentHour,
  required int currentMinute,
}) {
  final start = startHour * 60 + startMinute;
  final end = endHour * 60 + endMinute;
  final now = currentHour * 60 + currentMinute;
  if (start < 0 || end < 0) return false;
  return start > end ? now >= start || now <= end : now >= start && now <= end;
}

/// Reconstruction of 73970 qv4.q$a.f, checked against all original DEX jumps.
/// It recommends a startup/preload rendition; it never switches a player.
class RemoteDramaPolicy {
  RemoteDramaPolicy({
    RemoteDramaStrategy? lastStrategy,
    int lastStrategyTimeMilliseconds = 0,
  })  : _lastStrategy = lastStrategy,
        _lastStrategyTime = lastStrategyTimeMilliseconds;

  RemoteDramaStrategy? _lastStrategy;
  int _lastStrategyTime;
  RemoteDramaStrategy? get lastStrategy => _lastStrategy;
  int get lastStrategyTimeMilliseconds => _lastStrategyTime;

  void restoreKeepAlive(RemoteDramaStrategy? strategy, int timeMilliseconds) {
    _lastStrategy = strategy;
    _lastStrategyTime = timeMilliseconds;
  }

  void reset() => restoreKeepAlive(null, 0);

  RemoteDramaPolicyDecision evaluate(RemoteDramaPolicyInput input) {
    final missing = <String>{};
    if (!input.hasVideoModel) return RemoteDramaPolicyDecision(null, missing);
    final suggested = _prefabricated(input, missing);
    final downgrade = _downgrade(input, missing);
    final net = input.networkStrategy;
    String? result;
    if (net.enableNetResolution || input.useVideoarchPeakPeriod) {
      if (input.isPeakTime == null) {
        missing.add('isPeakTime');
      } else if (input.isPeakTime!) {
        final network = _byNetwork(
            input, net.netSpeedType, net.notMatchUseSmallest, missing);
        if (downgrade != null && network != null) {
          result =
              _orderedPair(downgrade, network, input.allowedDefinitions, false);
        } else {
          result = network ?? downgrade;
        }
      } else if (input.isPreload && net.lowerTimePreloadBestQuality) {
        final network = _byNetwork(
            input, net.netSpeedType, net.notMatchUseSmallest, missing);
        result = _orderedPair('720P', network, input.allowedDefinitions, true);
      } else {
        result = _byNetwork(
            input, net.netSpeedType, net.notMatchUseSmallest, missing);
      }
    } else {
      result = suggested.$1 != null
          ? (!suggested.$2 && downgrade != null ? downgrade : suggested.$1)
          : downgrade;
    }
    return RemoteDramaPolicyDecision(result, missing);
  }

  (String?, bool) _prefabricated(
      RemoteDramaPolicyInput input, Set<String> missing) {
    if (!(input.enableServerStrategy || input.enableV713Strategy) ||
        input.strategies == null) {
      return (null, false);
    }
    final previous = _lastStrategy;
    if (_lastStrategyTime > 0 &&
        previous != null &&
        previous.keepAliveDuration > 0) {
      // Dalvik mul-int/lit16 before widening to long, not an unbounded int.
      final ttl = (previous.keepAliveDuration * 1000).toSigned(32);
      final target =
          parseRemoteDramaResolution(previous.resolution?.toUpperCase());
      if (input.nowMilliseconds - _lastStrategyTime < ttl && target != null) {
        return (target, previous.ignorePeak);
      }
    }
    for (final item in input.strategies!) {
      final target = parseRemoteDramaResolution(item.resolution?.toUpperCase());
      if (target == null) continue;
      final condition = item.limitCondition;
      if (condition != null) {
        // The final digg interceptor rejects regardless of earlier inputs.
        if (input.diggStrategy) continue;
        final unknown = <String>{};
        var rejected = false;
        if (condition.isWifi) {
          if (input.networkAvailable == false || input.wifiEnabled == false) {
            rejected = true;
          } else {
            if (input.networkAvailable == null) unknown.add('networkAvailable');
            if (input.wifiEnabled == null) unknown.add('wifiEnabled');
          }
        }
        if (!rejected && condition.checkNetSpeed) {
          final network = _byNetwork(input, 2, false, unknown);
          rejected = network == null || _rank(network) < _rank(target);
        }
        final speedCondition = condition.netSpeed;
        if (!rejected && speedCondition != null) {
          final speed = input.nativePredictorBitsPerSecond;
          if (speed == null) {
            unknown.add('nativePredictorBitsPerSecond');
          } else {
            final kbps = speed / 1000 / 8;
            rejected = switch (speedCondition.checkNetType) {
              1 => kbps < speedCondition.networkSpeed,
              2 => kbps >= speedCondition.networkSpeed,
              _ => true,
            };
          }
        }
        if (unknown.isNotEmpty) {
          missing.addAll(unknown);
          return (null, false);
        }
        if (rejected) continue;
      }
      // Store the original object; a keep-alive hit does not renew its clock.
      _lastStrategy = item;
      _lastStrategyTime = input.nowMilliseconds;
      return (target, item.ignorePeak);
    }
    return (null, false);
  }

  String? _downgrade(RemoteDramaPolicyInput input, Set<String> missing) {
    if (input.enableServerPeak || input.useVideoarchPeakPeriod) {
      final server = input.serverPeak;
      if (server != null) {
        if (server.limitIndex != -1 &&
            input.episodeIndex != -1 &&
            input.episodeIndex <= server.limitIndex) {
          return null;
        }
        return server.enabled
            ? parseRemoteDramaResolution(server.resolution)
            : null;
      }
    }
    final config = input.localPeak;
    var type = config.resolutionType;
    if (config.resolutionTypeForLow != 0) {
      if (input.isLowDevice == null) {
        missing.add('isLowDevice');
        return null;
      }
      if (input.isLowDevice!) type = config.resolutionTypeForLow;
    }
    if (!(config.resolutionTypeForLow != 0 && input.isLowDevice == true) &&
        config.resolutionTypeForMidLow != 0) {
      if (input.isMiddleLowDevice == null) {
        missing.add('isMiddleLowDevice');
        return null;
      }
      if (input.isMiddleLowDevice!) type = config.resolutionTypeForMidLow;
    }
    if (type == 0) return null;
    if (input.isPeakTime == null) {
      missing.add('isPeakTime');
      return null;
    }
    if (!input.isPeakTime!) return null;
    final target = switch (type) { 1 => '540P', 2 => '480P', _ => null };
    return input.allowedDefinitions.contains(target) ? target : null;
  }

  static String? _orderedPair(
      String first, String? second, List<String> allowed, bool higher) {
    final firstIndex = allowed.indexOf(first);
    final secondIndex = allowed.indexOf(second ?? '');
    if (firstIndex >= 0 && secondIndex >= 0) {
      return higher
          ? (firstIndex <= secondIndex ? second : first)
          : (firstIndex >= secondIndex ? second : first);
    }
    if (secondIndex >= 0) return second;
    return firstIndex >= 0 ? first : null;
  }

  static String? _byNetwork(RemoteDramaPolicyInput input, int type,
      bool notMatchUseSmallest, Set<String> missing) {
    final items = input.renditions;
    if (items == null || items.isEmpty) return null;
    double target;
    if (type == 1) {
      final value = input.portraitTargetMegabitsPerSecond;
      if (value == null) {
        missing.add('portraitTargetMegabitsPerSecond');
        return null;
      }
      target = value;
    } else if (type == 2) {
      final value = input.nativePredictorBitsPerSecond;
      if (value == null) {
        missing.add('nativePredictorBitsPerSecond');
        return null;
      }
      target = value / 1000000;
    } else {
      target = 0;
    }
    if (target <= 0) return null;
    final function = input.bitrateFunction;
    if (function != null) {
      try {
        final parts = function.split(',');
        // Assignment occurs after all parsing, preserving target on failure.
        target = double.parse(parts[0]) * math.pow(target, 3) +
            double.parse(parts[1]) * math.pow(target, 2) +
            double.parse(parts[2]) * target +
            double.parse(parts[3]);
        if (target <= 0) return null;
      } on Object {
        // Original code catches malformed/non-string function configuration.
      }
    }
    final budget = target * 1000000;
    var minimum = double.maxFinite;
    var distance = double.maxFinite;
    String? lowest, selected;
    for (final item in items) {
      if (item == null) continue;
      if (lowest == null || item.bitrate < minimum) {
        lowest = item.definition;
        minimum = item.bitrate.toDouble();
      }
      if (item.bitrate <= budget) {
        final delta = budget - item.bitrate;
        if (delta < distance) {
          distance = delta;
          selected = item.definition;
        }
      }
    }
    return selected ?? (notMatchUseSmallest ? lowest : null);
  }
}
