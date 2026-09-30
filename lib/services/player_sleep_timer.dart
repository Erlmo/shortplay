import 'dart:async';

import 'package:flutter/foundation.dart';

/// 使用截止时间，应用从后台恢复时也能立即判断是否到期。
class PlayerSleepTimer extends ChangeNotifier {
  PlayerSleepTimer({required this.onElapsed, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final VoidCallback onElapsed;
  final DateTime Function() _now;
  Timer? _timer;
  DateTime? _deadline;
  bool _disposed = false;

  bool get isActive => _deadline != null;
  Duration get remaining {
    final deadline = _deadline;
    if (deadline == null) return Duration.zero;
    final value = deadline.difference(_now());
    return value.isNegative ? Duration.zero : value;
  }

  void start(Duration duration) {
    if (_disposed) return;
    if (duration <= Duration.zero) throw ArgumentError.value(duration);
    _timer?.cancel();
    _deadline = _now().add(duration);
    _timer = Timer(duration, checkDeadline);
    notifyListeners();
  }

  void cancel() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    notifyListeners();
  }

  void checkDeadline() {
    if (_disposed || _deadline == null) return;
    final left = remaining;
    if (left > Duration.zero) {
      _timer?.cancel();
      _timer = Timer(left, checkDeadline);
      return;
    }
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    notifyListeners();
    onElapsed();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
