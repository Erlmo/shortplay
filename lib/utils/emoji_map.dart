/// 弹幕表情代码 → 表情字符。共 53 个，与红果 assets/emoji_config.json 的代码表
/// （version 5，size 53）完全一致。显示时用 Twemoji（CC-BY 4.0）图片，
/// 文件在 assets/emoji/<码点>.png，见 [danmakuEmojiAsset]。
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

/// 表情字符对应的 Twemoji 图片资源路径（按 Twemoji 规则：码点小写十六进制用 - 连接，
/// 非 ZWJ 序列去掉变体选择符 FE0F）。
String danmakuEmojiAsset(String emoji) {
  final cps = emoji.runes.map((r) => r.toRadixString(16)).toList();
  final name = cps.contains('200d')
      ? cps.join('-')
      : cps.where((c) => c != 'fe0f').join('-');
  return 'assets/emoji/$name.png';
}

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
    final emoji = kDanmakuEmojiMap[m.group(0)!];
    if (emoji == null) continue;
    buffer.write(text.substring(last, m.start));
    if (buffer.isNotEmpty) {
      runs.add(DanmakuRun.text(buffer.toString()));
      buffer.clear();
    }
    runs.add(DanmakuRun.emoji(danmakuEmojiAsset(emoji), emoji));
    last = m.end;
  }
  buffer.write(text.substring(last));
  if (buffer.isNotEmpty) runs.add(DanmakuRun.text(buffer.toString()));
  return runs;
}
