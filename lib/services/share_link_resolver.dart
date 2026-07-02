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

  /// 从分享文本《剧名》中提取剧名（本地兜底用，服务端通常也会返回）。
  static String? extractTitle(String text) =>
      _titleReg.firstMatch(text)?.group(1)?.trim();

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
