import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/share_link_resolver.dart';

void main() {
  group('extractShareUrl', () {
    test('从混合中文文本里提取短链，不吞掉书名号剧名', () {
      const text =
          '《横穿古今：我在古代搞事业》免费看全集https://novelquickapp.com/s/gk-2rqFvuJU/';
      expect(
        ShareLinkResolver.extractShareUrl(text),
        'https://novelquickapp.com/s/gk-2rqFvuJU/',
      );
    });

    test('无分享链接返回 null', () {
      expect(ShareLinkResolver.extractShareUrl('随便一段没有链接的文字'), isNull);
    });
  });

  group('extractTitle', () {
    test('提取《》中的剧名', () {
      const text = '《横穿古今：我在古代搞事业》免费看全集https://novelquickapp.com/s/x';
      expect(ShareLinkResolver.extractTitle(text), '横穿古今：我在古代搞事业');
    });
  });

  group('parseSeriesIdFromLocation', () {
    test('从真实双重编码 location 解析 video_series_id', () {
      const location =
          'https://novelquickapp.com/hongguo/ug/pages/video-list-share-ssr?encrypt_did=x&zlink=https%3A%2F%2Fapplink.novelquickapp.com%2FdVu4P%3FschemeParams%3D%257B%2522video_series_id%2522%253A%25227579666985684831294%2522%252C%2522vs_id_type%2522%253A%25221%2522%257D&did=y';
      expect(
        ShareLinkResolver.parseSeriesIdFromLocation(location),
        '7579666985684831294',
      );
    });

    test('正则兜底：直接含明文 JSON', () {
      const location = 'https://x.com/p?data={"video_series_id":"123456789"}';
      expect(
        ShareLinkResolver.parseSeriesIdFromLocation(location),
        '123456789',
      );
    });

    test('整剧分享：video_series_id 有值时优先用它', () {
      const location =
          'https://x.com/p?a={"video_series_id":"111","video_id":"222","vid":"333"}';
      expect(ShareLinkResolver.parseSeriesIdFromLocation(location), '111');
    });

    test('单集分享：video_series_id 为空时回退到 video_id', () {
      // 来自真实动态漫画分享链接：series_id 空，落到 video_id。
      const location =
          'https://novelquickapp.com/hongguo/ug/pages/video-animation-share?zlink=https%3A%2F%2Fapplink.novelquickapp.com%2FdVu4P%3FschemeParams%3D%257B%2522video_series_id%2522%253A%2522%2522%252C%2522vid%2522%253A%25227643858507061529625%2522%252C%2522video_id%2522%253A%25227643856485763533886%2522%257D';
      expect(
        ShareLinkResolver.parseSeriesIdFromLocation(location),
        '7643856485763533886',
      );
    });

    test('无法解析返回 null', () {
      expect(
        ShareLinkResolver.parseSeriesIdFromLocation('https://x.com/p?a=b'),
        isNull,
      );
    });
  });
}
