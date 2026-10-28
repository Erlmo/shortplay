import 'package:dio/dio.dart';

import 'api_client.dart';

/// 分享链接解析结果。
class ShareLinkResult {
  const ShareLinkResult({required this.videoId, this.title});

  /// 番茄作品 id（videoid），用于拉取剧集列表 / 驱动播放。
  final String videoId;

  /// 服务端返回的剧名，用于播放页展示，可能为空。
  final String? title;
}

/// 解析分享口令，把整段剪贴板文本交给服务端 POST /nove/share。
///
/// 服务端负责跟随 302、解码、提取 videoid 与剧名。
/// 解析失败时返回 null（服务端返回非 0 code 或无法提取 videoId）。
class ShareLinkResolver {
  ShareLinkResolver({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  static final RegExp _titleReg = RegExp(r'《([^》]+)》');

  /// 候选 id 的参数名，顺序即优先级。
  ///
  /// - video_id：剧 / 作品 id
  /// - vid：分集 id
  /// - share_toast_vid：分享弹窗用的 id（可能与 vid 不同）
  /// - book_id：番茄小说 / 短剧的书籍 id
  static const List<String> idKeys = [
    'video_id',
    'vid',
    'share_toast_vid',
    'book_id',
  ];

  /// 从分享文本《剧名》中提取剧名（本地兜底用，服务端通常也会返回）。
  static String? extractTitle(String text) =>
      _titleReg.firstMatch(text)?.group(1)?.trim();

  /// 是否是红果 / 番茄系的分享域名。
  ///
  /// - novelquickapp.com：短剧 / 漫剧分享页，以及 /s/ 短链
  /// - hongguoduanju.com：红果短剧官网（/page/?book_id=…）
  static bool isShareHost(String host) {
    final h = host.toLowerCase();
    for (final domain in const ['novelquickapp.com', 'hongguoduanju.com']) {
      if (h == domain || h.endsWith('.$domain')) return true;
    }
    return false;
  }

  /// 从 query 里取剧目 / 分集 id 候选，只保留纯数字，
  /// 避免把 encrypt_did 之类的密文当成 id。
  static List<String> idsFromQuery(Map<String, String> query) {
    final result = <String>[];
    for (final key in idKeys) {
      final value = query[key]?.trim();
      if (value == null || value.isEmpty) continue;
      if (int.tryParse(value) == null) continue;
      if (!result.contains(value)) result.add(value);
    }
    return result;
  }

  /// 从页面 HTML 里取 id。
  ///
  /// 分享页把参数原样塞在 SSR 数据里：
  ///   window._SSR_DATA = {…,"request":{"query":{"video_id":"…","vid":"…"}}}
  /// 短链靠这个兜底——服务端是内部重写（始终 HTTP 200，没有 Location 头），
  /// 不一定会把最终 URL 暴露给客户端。
  static List<String> idsFromHtml(String html) {
    final result = <String>[];
    for (final key in idKeys) {
      final match = RegExp('"$key":"(\\d+)"').firstMatch(html);
      final value = match?.group(1);
      if (value == null || value.isEmpty) continue;
      if (!result.contains(value)) result.add(value);
    }
    return result;
  }

  /// 合并多个来源的候选 id，去重并保持优先级。
  static List<String> mergeIds(List<List<String>> sources) {
    final result = <String>[];
    for (final source in sources) {
      for (final id in source) {
        if (!result.contains(id)) result.add(id);
      }
    }
    return result;
  }

  /// 本地提取剧目标识候选（纯数字 id），按优先级排序。
  ///
  /// 安卓 / iOS 版红果分享的是短链（novelquickapp.com/s/xxxx），
  /// 鸿蒙版红果分享的是长链：
  ///
  ///   https://novelquickapp.com/hongguo/ug/pages/video-animation-share
  ///     ?video_id=...&vid=...&share_toast_vid=...
  ///
  /// 两者最终指向同一个页面，长链的 query 里已经带着剧目 id 与分集 id。
  /// 服务端 POST /nove/share 只认短链，鸿蒙长链会解析失败，
  /// 所以这里在本地先做一轮，调用方用 /nove/directory 能否取到集数
  /// 来判定哪个才是剧目标识。
  ///
  /// 返回空列表表示这段文本里没有可直接使用的 id，仍走服务端解析。
  static List<String> extractLocalIds(String text) {
    final urlMatch = RegExp(r'https?://[^\s]+').firstMatch(text);
    if (urlMatch == null) return const <String>[];

    final uri = Uri.tryParse(urlMatch.group(0)!);
    if (uri == null) return const <String>[];
    if (!isShareHost(uri.host)) return const <String>[];

    return idsFromQuery(uri.queryParameters);
  }

  /// 本地解析分享链接，拿到剧目标识候选。
  ///
  /// 短链（/s/xxxx）拉一次分享页，从最终 URL 的 query 与页面 HTML 的
  /// SSR 数据里取 id；长链直接取 query。整条链路不依赖服务端。
  static Future<List<String>> resolveLocalIds(String text) async {
    final urlMatch = RegExp(r'https?://[^\s]+').firstMatch(text);
    if (urlMatch == null) return const <String>[];

    var uri = Uri.tryParse(urlMatch.group(0)!);
    if (uri == null) return const <String>[];
    if (!isShareHost(uri.host)) return const <String>[];

    // 长链参数齐了就直接用，不必再发请求。
    final direct = idsFromQuery(uri.queryParameters);
    if (direct.isNotEmpty && !uri.path.startsWith('/s/')) return direct;

    final client = Dio(
      BaseOptions(
        followRedirects: true,
        maxRedirects: 5,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (status) => status != null && status < 400,
        responseType: ResponseType.plain,
      ),
    );
    try {
      final response = await client.get<String>(uri.toString());
      final html = response.data ?? '';
      return mergeIds([
        idsFromQuery(response.realUri.queryParameters),
        idsFromHtml(html),
        direct,
      ]);
    } catch (_) {
      // 拉不到就退回已知的 query 参数，再不行交回服务端处理。
      return direct;
    } finally {
      client.close(force: true);
    }
  }

  /// 解析一段剪贴板文本，返回作品 id（与可选剧名）。
  /// 返回 null 表示解析失败（非分享链接或其他错误）。
  Future<ShareLinkResult?> resolve(String clipboardText) async {
    if (clipboardText.trim().isEmpty) return null;

    try {
      final info = await _apiClient.fetchShareInfo(clipboardText);
      return ShareLinkResult(
        videoId: info.videoId,
        // 优先用服务端返回的剧名，没有则回退到口令里《》内的文本。
        title: info.title ?? extractTitle(clipboardText),
      );
    } catch (_) {
      // 解析失败返回 null，不向上抛出。
      return null;
    }
  }
}
