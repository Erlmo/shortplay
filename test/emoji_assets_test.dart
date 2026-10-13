import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/utils/emoji_map.dart';

void main() {
  test('53 个弹幕表情（与红果 emoji_config.json 一致）都有对应的 Twemoji 图片', () {
    expect(kDanmakuEmojiMap.length, 53);
    final missing = <String>[];
    kDanmakuEmojiMap.forEach((tag, emoji) {
      final asset = danmakuEmojiAsset(emoji);
      if (!File(asset).existsSync()) missing.add('$tag → $asset');
    });
    expect(missing, isEmpty);
  });

  test('弹幕内容拆成文字段和表情段，不认识的代码保留原文', () {
    final runs = splitDanmakuEmoji('好看[笑哭][赞]真的[不存在]');
    expect(runs.map((r) => r.isEmoji ? r.fallback : r.text).toList(),
        ['好看', '😂', '👍', '真的[不存在]']);
    expect(runs[1].asset, 'assets/emoji/1f602.png');
    expect(danmakuEmojiAsset('❤️'), 'assets/emoji/2764.png');
  });
}
