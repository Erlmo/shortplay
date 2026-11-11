import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户选择优先于网络策略；auto 保留原来的自动选档行为。
class PlaybackPreferences {
  static const preferenceKey = 'default_playback_definition_v1';
  static const definitions = ['auto', '360p', '480p', '540p', '720p', '1080p'];
  static final defaultDefinition = ValueNotifier<String>('auto');
  static Future<void> _writes = Future<void>.value();

  static String label(String value) =>
      value == 'auto' ? '自动（推荐）' : value.toUpperCase();

  static Future<void> _enqueue(Future<void> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static Future<void> load() => _enqueue(() async {
        final prefs = await SharedPreferences.getInstance();
        final value = prefs.getString(preferenceKey);
        defaultDefinition.value = definitions.contains(value) ? value! : 'auto';
      });

  static Future<void> save(String definition) {
    if (!definitions.contains(definition)) throw ArgumentError('不支持的默认清晰度');
    return _enqueue(() async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(preferenceKey, definition)) {
        throw StateError('默认清晰度保存失败');
      }
      defaultDefinition.value = definition;
    });
  }
}
