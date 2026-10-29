import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/twixive.dart';

/// 与短剧播放历史分开保存。以视频 ID 去重，最新喜欢的视频排在前面。
class LikedVideoStore {
  static const preferenceKey = 'liked_direct_videos_v1';
  static final revision = ValueNotifier<int>(0);
  static Future<void> _writes = Future<void>.value();

  static List<TwixiveVideo> _read(SharedPreferences preferences) {
    final raw = preferences.getString(preferenceKey);
    if (raw == null) return [];
    final json = jsonDecode(raw);
    if (json is! List) throw const FormatException('喜欢列表格式异常');
    final ids = <String>{};
    return json
        .whereType<Map>()
        .map((item) => TwixiveVideo.fromJson(Map<String, dynamic>.from(item)))
        .where((video) =>
            video.id.isNotEmpty && video.url.isNotEmpty && ids.add(video.id))
        .toList();
  }

  static Future<List<TwixiveVideo>> load() async {
    await _writes;
    return _read(await SharedPreferences.getInstance());
  }

  static Future<bool> contains(String id) async =>
      (await load()).any((video) => video.id == id);

  static Future<bool> toggle(TwixiveVideo video) {
    // 串行写入，两个播放页或快速操作不会覆盖彼此的喜欢记录。
    final operation = _writes.then((_) async {
      if (video.id.isEmpty || video.url.isEmpty) throw ArgumentError('缺少视频信息');
      final preferences = await SharedPreferences.getInstance();
      final videos = _read(preferences);
      final liked = !videos.any((item) => item.id == video.id);
      videos.removeWhere((item) => item.id == video.id);
      if (liked) videos.insert(0, video);
      if (!await preferences.setString(preferenceKey,
          jsonEncode(videos.map((item) => item.toJson()).toList()))) {
        throw StateError('喜欢保存失败');
      }
      revision.value++;
      return liked;
    });
    _writes =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }
}
