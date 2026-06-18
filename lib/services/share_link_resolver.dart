import 'dart:convert';

import 'package:dio/dio.dart';

/// 剪贴板分享链接解析结果。
class ShareLinkResult {
  const ShareLinkResult({required this.seriesId, this.title});

  /// 番茄剧集 id（video_series_id / book_id），用于拉取剧集列表。
  final String seriesId;

  /// 从分享文本《》中提取的剧名，仅用于播放页展示，可能为空。
  final String? title;
}

/// 解析「红果/番茄」短剧分享链接，提取出可用于播放的剧集 id。
///
/// 整体链路（与剪贴板内容一一对应）：
///   1. 从分享文本里匹配出 novelquickapp.com 短链；
///   2. 请求短链拿 302 的 location（带 zlink 参数的长链）；
///   3. location?zlink= 解码一层得到 applink 长链；
///   4. applink?schemeParams= 再解码一层得到 JSON；
///   5. JSON.video_series_id 即剧集 id。
///
/// 使用独立 [Dio]，绝不复用 ApiClient 的实例 —— 后者带番茄签名拦截器，
/// 给第三方域名加签名头既无意义又会泄露请求特征。
class ShareLinkResolver {
  ShareLinkResolver({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                followRedirects: false, // 手动跟随，才能读到 location
                validateStatus: (status) => status != null && status < 500,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
              ),
            );

  final Dio _dio;

  /// 匹配 URL 的字符集刻意排除空白与中文（含书名号），避免把链接后面紧跟的
  /// 中文剧名一并吞进来。
  static final RegExp _urlReg = RegExp(r'https?://[^\s一-鿿《》]+');

  static final RegExp _titleReg = RegExp(r'《([^》]+)》');

  /// 从任意文本中提取第一个 novelquickapp 分享短链；没有则返回 null。
  static String? extractShareUrl(String text) {
    for (final match in _urlReg.allMatches(text)) {
      final url = match.group(0)!;
      if (url.contains('novelquickapp.com')) return url;
    }
    return null;
  }

  /// 从分享文本《剧名》中提取剧名，没有则返回 null。
  static String? extractTitle(String text) =>
      _titleReg.firstMatch(text)?.group(1)?.trim();

  /// 判断文本是否包含可解析的分享链接（剪贴板快速预筛）。
  static bool looksLikeShareText(String text) =>
      text.contains('novelquickapp.com');

  /// 解析一段剪贴板文本，返回剧集 id（与可选剧名）。解析失败返回 null。
  Future<ShareLinkResult?> resolve(String clipboardText) async {
    final shareUrl = extractShareUrl(clipboardText);
    if (shareUrl == null) return null;

    final location = await _followRedirect(shareUrl);
    if (location == null) return null;

    final seriesId = parseSeriesIdFromLocation(location);
    if (seriesId == null) return null;

    return ShareLinkResult(
      seriesId: seriesId,
      title: extractTitle(clipboardText),
    );
  }

  /// 请求短链，返回 302/301 的 location。最多跟随 5 跳，命中带 zlink 的长链即停。
  Future<String?> _followRedirect(String url) async {
    var current = url;
    for (var hop = 0; hop < 5; hop++) {
      final response = await _dio.get<dynamic>(current);
      final status = response.statusCode ?? 0;
      if (status < 300 || status >= 400) {
        // 非重定向：若当前 url 已带 zlink，直接用它解析。
        return current.contains('zlink=') ? current : null;
      }
      final location = response.headers.value('location');
      if (location == null || location.isEmpty) return null;
      if (location.contains('zlink=')) return location;
      current = location;
    }
    return null;
  }

  /// 从 302 location 解析出可用于拉剧集的 id。
  ///
  /// 正常结构：location?zlink=[applink]，applink?schemeParams=[json]。
  /// Uri.queryParameters 每解析一层自动解一次 URL 编码，故逐层取参数即可。
  ///
  /// 整剧分享 json.video_series_id 有值，直接用。但「播放器里分享单集」的链接
  /// （动态漫画 motion_comic 等）video_series_id 为空，真正的标识落在 video_id
  /// （作品）和 vid（单集）上 —— 按 video_series_id → video_id → vid 优先级回退，
  /// video_id 更接近 directory 接口要的 book_id。任何异常回退到正则直取。
  static const _idKeys = ['video_series_id', 'video_id', 'vid'];

  static String? parseSeriesIdFromLocation(String location) {
    try {
      final zlink = Uri.parse(location).queryParameters['zlink'];
      if (zlink != null && zlink.isNotEmpty) {
        final schemeParams = Uri.parse(zlink).queryParameters['schemeParams'];
        if (schemeParams != null && schemeParams.isNotEmpty) {
          final json = jsonDecode(schemeParams);
          if (json is Map) {
            for (final key in _idKeys) {
              final id = json[key]?.toString();
              if (id != null && id.isNotEmpty) return id;
            }
          }
        }
      }
    } catch (_) {
      // 结构变化或解码失败，落到下面的正则兜底。
    }
    // 兜底：不管编码层数，按同样优先级直接在整串里捞 id 的值。
    // 覆盖 "video_id":"123"、%22video_id%22%3A%22123%22 等形态，跳过空串。
    for (final key in _idKeys) {
      final match = RegExp(
        '$key(?:%22|")?(?:%3A|:)(?:%22|")?(\\d+)',
      ).firstMatch(location);
      final id = match?.group(1);
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }
}



