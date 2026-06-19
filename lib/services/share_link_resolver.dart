import 'api_client.dart';

/// 分享链接解析结果。
class ShareLinkResult {
  const ShareLinkResult({required this.videoId, this.title});

  /// 番茄作品 id（videoid），用于拉取剧集列表 / 驱动播放。
  final String videoId;

  /// 服务端返回的剧名，用于播放页展示，可能为空。
  final String? title;
}

/// 解析「红果/番茄」短剧分享口令。
///
/// 解析逻辑已下沉到服务端 POST /nove/share（见 [ApiClient.fetchShareInfo]）：
/// 客户端把整段剪贴板文本发过去，服务端负责跟随 302、解码、提取 videoid 与剧名。
/// 客户端只做本地快速预筛（是否像分享口令）避免无谓请求。
class ShareLinkResolver {
  ShareLinkResolver({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  static final RegExp _titleReg = RegExp(r'《([^》]+)》');

  /// 判断文本是否包含可解析的分享链接（剪贴板快速预筛）。
  static bool looksLikeShareText(String text) =>
      text.contains('novelquickapp.com');

  /// 从分享文本《剧名》中提取剧名（本地兜底用，服务端通常也会返回）。
  static String? extractTitle(String text) =>
      _titleReg.firstMatch(text)?.group(1)?.trim();

  /// 解析一段剪贴板文本，返回作品 id（与可选剧名）。
  /// 文本不像分享口令时返回 null；网络/服务端错误会向上抛出。
  Future<ShareLinkResult?> resolve(String clipboardText) async {
    if (!looksLikeShareText(clipboardText)) return null;

    final info = await _apiClient.fetchShareInfo(clipboardText);
    return ShareLinkResult(
      videoId: info.videoId,
      // 优先用服务端返回的剧名，没有则回退到口令里《》内的文本。
      title: info.title ?? extractTitle(clipboardText),
    );
  }
}
