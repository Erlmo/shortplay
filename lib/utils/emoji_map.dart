/// 弹幕表情代码 → 备用表情字符。共 53 个，顺序与红果 assets/emoji_config.json
/// 的代码表（version 5，size 53）一致，第 N 个对应 assets/danmaku_emoji/NN.webp，
/// 见 [danmakuEmojiAsset]。图片加载失败时才显示这里的表情字符。
const Map<String, String> kDanmakuEmojiMap = {
  '[微笑]': '😊',
  '[偷笑]': '🤭',
  '[笑]': '😄',
  '[什么]': '😳',
  '[害羞]': '🥰',
  '[爱慕]': '😍',
  '[飞吻]': '😘',
  '[奸笑]': '😏',
  '[尬笑]': '😅',
  '[思考]': '🤔',
  '[撇嘴]': '😒',
  '[做鬼脸]': '🤪',
  '[酷]': '😎',
  '[翻白眼]': '🙄',
  '[惊呆]': '😲',
  '[震惊]': '😱',
  '[送心]': '💕',
  '[委屈]': '🥺',
  '[快哭了]': '😢',
  '[笑哭]': '😂',
  '[哭]': '😭',
  '[大笑]': '🤣',
  '[舔屏]': '🤤',
  '[怒]': '😡',
  '[捂脸]': '🤦',
  '[吐]': '🤮',
  '[恐惧]': '😨',
  '[抓狂]': '🤯',
  '[敬礼]': '🫡',
  '[石化]': '🗿',
  '[OK]': '👌',
  '[赞]': '👍',
  '[爱心]': '❤️',
  '[伤心]': '💔',
  '[KISS]': '💋',
  '[懂了]': '👀',
  '[探究]': '🧐',
  '[重拳出击]': '👊',
  '[吃瓜]': '🍉',
  '[盯]': '👁️',
  '[你细品]': '🫣',
  '[赶稿中]': '✍️',
  '[注意]': '⚠️',
  '[饱了]': '🫃',
  '[码住]': '📌',
  '[学会了]': '✅',
  '[顶帖]': '🔝',
  '[求爆更]': '🔥',
  '[求关注]': '🙏',
  '[爽]': '😆',
  '[鼓掌]': '👏',
  '[没看够]': '🥹',
  '[送花]': '🌹',
};

final RegExp _emojiTagPattern = RegExp(r'\[[^\]]+\]');

String replaceDanmakuEmoji(String text) {
  return text.replaceAllMapped(_emojiTagPattern, (match) {
    final tag = match.group(0)!;
    return kDanmakuEmojiMap[tag] ?? tag;
  });
}

final Map<String, int> _emojiIndex = {
  for (final (i, tag) in kDanmakuEmojiMap.keys.indexed) tag: i + 1,
};

/// 表情代码（如 "[笑哭]"）对应的图片资源路径；不认识的代码返回 null。
String? danmakuEmojiAsset(String tag) {
  final index = _emojiIndex[tag];
  if (index == null) return null;
  return 'assets/danmaku_emoji/${index.toString().padLeft(2, '0')}.webp';
}

/// 全部 53 个表情图片的资源路径（按代码表顺序）。
Iterable<String> get danmakuEmojiAssets =>
    kDanmakuEmojiMap.keys.map((tag) => danmakuEmojiAsset(tag)!);

/// 弹幕内容拆成的一段：普通文字，或一个表情（[asset] 为图片，[fallback] 为表情字符）。
class DanmakuRun {
  const DanmakuRun.text(this.text)
      : asset = null,
        fallback = null;
  const DanmakuRun.emoji(this.asset, this.fallback) : text = null;
  final String? text;
  final String? asset;
  final String? fallback;
  bool get isEmoji => asset != null;
}

/// 把 "好看[笑哭][赞]" 拆成文字段和表情段；不认识的 [xxx] 原样保留为文字。
List<DanmakuRun> splitDanmakuEmoji(String text) {
  final runs = <DanmakuRun>[];
  final buffer = StringBuffer();
  var last = 0;
  for (final m in _emojiTagPattern.allMatches(text)) {
    final tag = m.group(0)!;
    final emoji = kDanmakuEmojiMap[tag];
    if (emoji == null) continue;
    buffer.write(text.substring(last, m.start));
    if (buffer.isNotEmpty) {
      runs.add(DanmakuRun.text(buffer.toString()));
      buffer.clear();
    }
    runs.add(DanmakuRun.emoji(danmakuEmojiAsset(tag), emoji));
    last = m.end;
  }
  buffer.write(text.substring(last));
  if (buffer.isNotEmpty) runs.add(DanmakuRun.text(buffer.toString()));
  return runs;
}
