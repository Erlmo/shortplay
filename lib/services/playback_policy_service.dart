import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

Map<String, dynamic> _policyMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

Map<String, dynamic>? _policyJson(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    final decoded = jsonDecode(value);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

int _policyInt(Object? value, int fallback) => value is int ? value : fallback;
bool _policyBool(Object? value, bool fallback) =>
    value is bool ? value : fallback;

/// Measured host data only. Neither disk speed nor guessed hardware tiers are
/// substituted for TT's predictor, portrait score or device classification.
class PlaybackPolicyMeasurements {
  const PlaybackPolicyMeasurements(
      {this.networkAvailable,
      this.wifiEnabled,
      this.isLowDevice,
      this.isMiddleLowDevice,
      this.predictorBitsPerSecond,
      this.portraitTargetMegabitsPerSecond});
  final bool? networkAvailable, wifiEnabled, isLowDevice, isMiddleLowDevice;
  final double? predictorBitsPerSecond, portraitTargetMegabitsPerSecond;
}

class _PeakWindow {
  _PeakWindow(Map<String, dynamic> config, int Function(int) random) {
    List<int>? parse(Object? value) {
      if (value is! String) return null;
      final parts = value.split(':');
      if (parts.length != 2) return null;
      if (parts.any((part) => !RegExp(r'^[+-]?[0-9]+$').hasMatch(part))) {
        return null;
      }
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h == null || m == null || h < 0 || h > 24 || m < 0 || m > 60) {
        return null;
      }
      return [h, m];
    }

    final start = parse(config['peak_start']);
    final end = parse(config['peak_end']);
    if (start == null || end == null) return;
    var range = _policyInt(config['peak_random_range_min'], 0);
    // Operational bound for malformed remote input; never guess a window.
    if (range > 1440) return;
    if (range < 0) range = 0;
    final offset = range > 0 ? random(range + 1) : 0;
    _window = [
      start[0],
      start[1],
      (end[0] + (end[1] + offset) ~/ 60) % 24,
      (end[1] + offset) % 60
    ];
  }
  List<int>? _window;
  bool? contains(DateTime now) {
    final w = _window;
    return w == null
        ? null
        : remoteDramaMinuteInRange(
            startHour: w[0],
            startMinute: w[1],
            endHour: w[2],
            endMinute: w[3],
            currentHour: now.hour,
            currentMinute: now.minute);
  }
}

/// Original policy JSON updates run beside playback. No refresh is awaited by
/// video resolution, cache preparation or player creation.
class PlaybackPolicyService {
  PlaybackPolicyService({
    required this.fetch,
    DateTime Function()? clock,
    int Function(int)? random,
    PlaybackPolicyMeasurements Function()? measurements,
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? math.Random().nextInt,
        _measurements =
            measurements ?? (() => const PlaybackPolicyMeasurements());

  /// null means an older server has no policy endpoint; stop background polls.
  final Future<Map<String, dynamic>?> Function() fetch;
  final DateTime Function() _clock;
  final int Function(int) _random;
  final PlaybackPolicyMeasurements Function() _measurements;
  final _policy = RemoteDramaPolicy();
  Map<String, dynamic>? _settings;
  Map<String, dynamic>? _data;
  _PeakWindow? _peak;
  Timer? _timer;
  bool _running = false, _loading = false, _disposed = false;
  bool _useVideoarchPeakPeriod = false;
  int _failures = 0;
  Duration? get nextRefresh => _nextRefresh;
  Duration? _nextRefresh;
  bool get hasSettings => _settings != null;
  int get failures => _failures;

  Map<String, dynamic> _config(String key) => _policyMap(_settings?[key]);
  bool get preferCache =>
      _policyBool(_config('series_resolution_v635')['opt_cache'], true);

  List<String> allowedDefinitions(List<String> host) {
    final raw = _config('series_resolution_v635')['supported_definitions'];
    if (raw is! String || raw.isEmpty) return host;
    final filtered =
        host.where((item) => raw.contains(item.toUpperCase())).toList();
    return filtered.isEmpty ? host : filtered;
  }

  void start() {
    if (_running || _disposed) return;
    _running = true;
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_loading || _disposed) return;
    _loading = true;
    try {
      final response = await fetch();
      if (_disposed) return;
      if (response == null) {
        _running = false;
        _timer?.cancel();
        return;
      }
      accept(response);
    } catch (error) {
      if (_disposed) return;
      recordFailure();
      debugPrint('[PlaybackSDK] 策略刷新失败，保留播放兜底: $error');
    } finally {
      _loading = false;
    }
  }

  void accept(Map<String, dynamic> response) {
    if (response['protocol'] != 1 || response['settings'] is! Map) {
      throw const FormatException('播放策略格式无效');
    }
    final raw = response['data'];
    if (raw != null && raw is! Map) throw const FormatException('远端策略格式无效');
    // Original Kotlin Lazy models latch in this process. New dynamic strategy
    // responses update below without rewriting prepared players or keep-alive.
    if (_settings == null) {
      _settings = Map.unmodifiable(_policyMap(response['settings']));
      _peak = _PeakWindow(_config('peak_time_v629'), _random);
    }
    _data = raw == null ? null : _policyMap(raw);
    _useVideoarchPeakPeriod =
        _policyBool(_data?['use_videoarch_peak_period'], false);
    _failures = 0;
    final enabled = _policyBool(response['strategy_enabled'], true);
    var seconds = !enabled ? 3600 : _policyInt(_data?['query_gap'], 300);
    // Do not allow an invalid/zero gap to create a busy network loop.
    if (seconds <= 0 || seconds > 86400) seconds = 300;
    _schedule(Duration(seconds: seconds));
  }

  void recordFailure() {
    _failures++;
    if (_failures >= 3) {
      // Controller clears g/h/c after three failures, preserving d and n/o.
      _data = null;
    }
    _schedule(Duration(seconds: _failures * 10));
  }

  void _schedule(Duration delay) {
    _nextRefresh = delay;
    _timer?.cancel();
    if (_running && !_disposed) {
      _timer = Timer(delay, () => unawaited(refresh()));
    }
  }

  RemoteDramaPolicyDecision? evaluate({
    required List<RemoteDramaRendition?> renditions,
    required List<String> allowedDefinitions,
    required int episodeIndex,
    required bool isPreload,
  }) {
    if (_settings == null) return null;
    final now = _clock();
    final observed = _measurements();
    final flags = _config('video_play_resolution_strategy_1080_v671');
    final net = _config('resolution_net_strategy_v649');
    final peak = _config('resolution_in_peak_v629');
    final strategiesMap = _policyMap(_data?['strategies']);
    final server = _policyJson(strategiesMap['peak_demotion']);
    final prefabricated = _policyJson(strategiesMap['resolution_strategy']);
    final list = prefabricated?['resolution_strategy_list'];
    final strategies = list is List
        ? <RemoteDramaStrategy>[
            for (final item in list.whereType<Map>())
              _strategy(_policyMap(item))
          ]
        : null;
    bool? serverIsPeak = _data?['is_peak_period'] is bool
        ? _data!['is_peak_period'] as bool
        : null;
    final useLocal =
        !_policyBool(_config('playlet_peek_time_v691')['enable'], false);
    final localIsPeak = useLocal ? _peak?.contains(now) : null;
    // PlayerStrategyController.a(Boolean): videoarch override, then local,
    // then server. Unknown host's last fallback stays unknown.
    final isPeak = _useVideoarchPeakPeriod
        ? (serverIsPeak ?? false)
        : (localIsPeak ?? serverIsPeak);
    final function = _policyMap(
        _config('engine_net_report_v649')['bitrate_opt_function'])['ShortPlay'];
    return _policy.evaluate(RemoteDramaPolicyInput(
        hasVideoModel: true,
        enableServerStrategy: _policyBool(flags['enable_server'], false),
        enableV713Strategy: _policyBool(
            _config('short_video_resolution_v713')['enable'], false),
        diggStrategy: _policyBool(flags['digg_strategy'], false),
        enableServerPeak: _policyBool(
            _config('server_series_resolution_v655')['enable_server'], false),
        useVideoarchPeakPeriod: _useVideoarchPeakPeriod,
        networkStrategy: RemoteDramaNetStrategy(
            enableNetResolution:
                _policyBool(net['enable_net_resolution'], false),
            lowerTimePreloadBestQuality:
                _policyBool(net['lower_time_preload_best_quality'], false),
            netSpeedType: _policyInt(net['net_speed_type'], 1),
            notMatchUseSmallest:
                _policyBool(net['not_match_use_smallest'], false)),
        localPeak: RemoteDramaLocalPeak(
            resolutionType: _policyInt(peak['resolution_type'], 0),
            resolutionTypeForLow:
                _policyInt(peak['resolution_type_for_low'], 0),
            resolutionTypeForMidLow:
                _policyInt(peak['resolution_type_for_mid_low'], 0)),
        serverPeak: server == null
            ? null
            : RemoteDramaServerPeak(
                resolution: server['resolution'] is String
                    ? server['resolution'] as String
                    : null,
                enabled: serverIsPeak ?? false,
                limitIndex: _policyInt(
                    server['resolution_in_peak_min_episode_index'], -1)),
        strategies: strategies,
        renditions: renditions,
        allowedDefinitions: allowedDefinitions,
        isPreload: isPreload,
        episodeIndex: episodeIndex,
        nowMilliseconds: now.millisecondsSinceEpoch,
        isPeakTime: isPeak,
        isLowDevice: observed.isLowDevice,
        isMiddleLowDevice: observed.isMiddleLowDevice,
        networkAvailable: observed.networkAvailable,
        wifiEnabled: observed.wifiEnabled,
        nativePredictorBitsPerSecond: observed.predictorBitsPerSecond,
        portraitTargetMegabitsPerSecond:
            observed.portraitTargetMegabitsPerSecond,
        bitrateFunction: function is String ? function : null));
  }

  RemoteDramaStrategy _strategy(Map<String, dynamic> raw) {
    final limit = raw['limit_condition'];
    final condition = _policyMap(limit);
    final speed = condition['net_speed'];
    final network = _policyMap(speed);
    return RemoteDramaStrategy(
        resolution: raw['suggest_resolution_type'] is String
            ? raw['suggest_resolution_type'] as String
            : null,
        ignorePeak: _policyBool(raw['ignore_peak'], false),
        keepAliveDuration: _policyInt(raw['keep_alive_duration'], 0),
        limitCondition: limit is! Map
            ? null
            : RemoteDramaLimitCondition(
                isWifi: _policyBool(condition['is_wifi'], false),
                checkNetSpeed: _policyBool(condition['check_net_speed'], false),
                netSpeed: speed is! Map
                    ? null
                    : RemoteDramaSpeedCondition(
                        checkNetType: _policyInt(network['check_net_type'], 0),
                        networkSpeed:
                            _policyInt(network['network_speed'], 0))));
  }

  void dispose() {
    _disposed = true;
    _running = false;
    _timer?.cancel();
  }
}
