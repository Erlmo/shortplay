import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/utils/emoji_map.dart';

void main() {
  test('53 个弹幕表情（与红果 emoji_config.json 一致）都有对应的图片', () {
    expect(kDanmakuEmojiMap.length, 53);
    final missing = <String>[];
    for (final tag in kDanmakuEmojiMap.keys) {
      final asset = danmakuEmojiAsset(tag);
      if (asset == null || !File(asset).existsSync()) {
        missing.add('$tag → $asset');
      }
    }
    expect(missing, isEmpty);
    expect(danmakuEmojiAsset('[微笑]'), 'assets/danmaku_emoji/01.webp');
    expect(danmakuEmojiAsset('[送花]'), 'assets/danmaku_emoji/53.webp');
    expect(danmakuEmojiAsset('[不存在]'), isNull);
  });

  test('弹幕内容拆成文字段和表情段，不认识的代码保留原文', () {
    final runs = splitDanmakuEmoji('好看[笑哭][赞]真的[不存在]');
    expect(runs.map((r) => r.isEmoji ? r.fallback : r.text).toList(),
        ['好看', '😂', '👍', '真的[不存在]']);
    expect(runs[1].asset, 'assets/danmaku_emoji/20.webp');
    expect(runs[2].asset, 'assets/danmaku_emoji/32.webp');
  });
}
