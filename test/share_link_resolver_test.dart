import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/share_link_resolver.dart';

void main() {
  group('looksLikeShareText', () {
    test('包含 novelquickapp.com 视为分享口令', () {
      expect(
        ShareLinkResolver.looksLikeShareText(
          '《剧名》https://novelquickapp.com/s/x/',
        ),
        isTrue,
      );
    });

    test('普通文本不视为口令', () {
      expect(ShareLinkResolver.looksLikeShareText('随便一段没有链接的文字'), isFalse);
    });
  });

  group('extractTitle', () {
    test('提取《》中的剧名', () {
      const text = '《横穿古今：我在古代搞事业》免费看全集https://novelquickapp.com/s/x';
      expect(ShareLinkResolver.extractTitle(text), '横穿古今：我在古代搞事业');
    });

    test('无书名号返回 null', () {
      expect(ShareLinkResolver.extractTitle('没有书名号的文本'), isNull);
    });
  });
}
