import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playback_record.dart';

class PlaybackHistoryStore {
  static const String _key = 'playback_history_v1';
  static const int _maxItems = 50;

  /// 每次写入后自增。首页“继续观看”、历史页、详情页监听它来刷新，
  /// 不用等页面返回时再手动重载（退出播放页时的保存晚于路由返回）。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

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
    final existing = items
        .where((r) => r.dramaId != 0 && r.dramaId == record.dramaId)
        .firstOrNull;
    items.removeWhere((r) => r.dramaId != 0 && r.dramaId == record.dramaId);
    items.insert(
      0,
      PlaybackRecord(
        dramaId: record.dramaId,
        dramaName: record.dramaName == '分享短剧' && existing != null
            ? existing.dramaName
            : record.dramaName,
        cover: record.cover.isEmpty ? existing?.cover ?? '' : record.cover,
        episodeIndex: record.episodeIndex,
        episodeNumber: record.episodeNumber,
        positionMs: record.positionMs,
        updatedAtMs: record.updatedAtMs,
        // 同一集内的保存沿用已知的时长 / 集数
        durationMs: record.durationMs ??
            (existing?.episodeIndex == record.episodeIndex
                ? existing?.durationMs
                : null),
        episodeCount: record.episodeCount ?? existing?.episodeCount,
      ),
    );
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
    revision.value++;
  }

  static Future<void> _save(List<PlaybackRecord> items) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(
      items.map((e) => e.toJson()).toList(growable: false),
    );
    await prefs.setString(_key, raw);
    revision.value++;
  }
}
