import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/drama.dart';

/// 本机短剧收藏，独立于播放记录与榜单保存。
class FavoriteDramaStore {
  static const preferenceKey = 'favorite_dramas_v1';
  static final revision = ValueNotifier<int>(0);
  static Future<void> _writes = Future<void>.value();

  static String keyOf(Drama drama) => '${drama.isTheaterResource}:${drama.id}';

  static List<Drama> _read(SharedPreferences prefs) {
    final raw = prefs.getString(preferenceKey);
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('收藏数据格式异常');
    return decoded
        .whereType<Map>()
        .map((item) {
          final data = Map<String, dynamic>.from(item);
          final base = Drama.fromJson(data);
          return Drama(
            id: base.id,
            name: base.name,
            actors: base.actors,
            cover: base.cover,
            intro: base.intro,
            tags: base.tags,
            status: base.status,
            updateTime: base.updateTime,
            isTheaterResource: data['theater'] == true,
            score: data['score'] as String?,
            recText: data['rec_text'] as String?,
          );
        })
        .where((drama) => drama.id != 0)
        .toList();
  }

  static Future<List<Drama>> load() async {
    await _writes;
    return _read(await SharedPreferences.getInstance());
  }

  static Future<bool> contains(Drama drama) async =>
      (await load()).any((item) => keyOf(item) == keyOf(drama));

  static Future<bool> toggle(Drama drama) => _change(drama);

  static Future<void> remove(Drama drama) async {
    await _change(drama, saved: false);
  }

  static Future<bool> _change(Drama drama, {bool? saved}) {
    final operation = _writes.then((_) async {
      if (drama.id == 0) throw ArgumentError('缺少短剧信息');
      final prefs = await SharedPreferences.getInstance();
      final items = _read(prefs);
      final key = keyOf(drama);
      final added = saved ?? !items.any((item) => keyOf(item) == key);
      items.removeWhere((item) => keyOf(item) == key);
      if (added) items.insert(0, drama);
      await _save(prefs, items);
      return added;
    });
    _writes =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  static Future<void> removeMany(Iterable<String> keys) {
    final selected = keys.toSet();
    if (selected.isEmpty) return Future<void>.value();
    final operation = _writes.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final items = _read(prefs)
        ..removeWhere((item) => selected.contains(keyOf(item)));
      await _save(prefs, items);
    });
    _writes =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  static Future<void> _save(SharedPreferences prefs, List<Drama> items) async {
    final persisted = await prefs.setString(
        preferenceKey,
        jsonEncode(items
            .map((item) => {
                  'id': item.id,
                  'name': item.name,
                  'actors': item.actors,
                  'cover': item.cover,
                  'intro': item.intro,
                  'tags': item.tags,
                  'status': item.status,
                  'update_time': item.updateTime,
                  'theater': item.isTheaterResource,
                  'score': item.score,
                  'rec_text': item.recText,
                })
            .toList()));
    if (!persisted) throw StateError('收藏保存失败');
    revision.value++;
  }
}
