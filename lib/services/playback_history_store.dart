import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/playback_record.dart';

class PlaybackHistoryStore {
  static const String _key = 'playback_history_v1';
  static const int _maxItems = 50;

  static Future<List<PlaybackRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final items = <PlaybackRecord>[];
      for (final item in decoded) {
        if (item is Map) {
          items.add(PlaybackRecord.fromJson(item.cast<String, dynamic>()));
        }
      }
      items.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      return items;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> upsert(PlaybackRecord record) async {
    final items = (await load()).toList(growable: true);
    items.removeWhere((r) => r.dramaId != 0 && r.dramaId == record.dramaId);
    items.insert(0, record);
    if (items.length > _maxItems) {
      items.removeRange(_maxItems, items.length);
    }
    await _save(items);
  }

  static Future<void> removeByDramaId(int dramaId) async {
    final items = (await load()).toList(growable: true);
    items.removeWhere((r) => r.dramaId == dramaId);
    await _save(items);
  }

  static Future<void> removeByKey(int dramaId) async {
    final items = (await load()).toList(growable: true);
    items.removeWhere((r) => dramaId != 0 && r.dramaId == dramaId);
    await _save(items);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<void> _save(List<PlaybackRecord> items) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(
      items.map((e) => e.toJson()).toList(growable: false),
    );
    await prefs.setString(_key, raw);
  }
}
