import 'dart:io';

import '../models/episode.dart';
import 'download_service.dart';

class OfflinePlaybackCache {
  /// 离线只允许读取实际存在的本地文件，统一生成正确转义的 file URI。
  static Future<String> playableFileUri(String source) async {
    final uri = Uri.tryParse(source);
    if (source.isEmpty ||
        (uri != null && uri.hasScheme && uri.scheme != 'file')) {
      throw const FileSystemException('本地缓存路径无效，请重新下载');
    }
    final file = uri?.scheme == 'file' ? File.fromUri(uri!) : File(source);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw FileSystemException('本地缓存已丢失或为空，请重新下载', source);
    }
    return file.absolute.uri.toString();
  }

  static List<Episode> completedEpisodesFromGroup(DramaDownloadGroup group) {
    return group.episodes
        .where((episode) => episode.isPlayable)
        .map(
          (episode) => Episode(
            index: episode.episode.index,
            name: episode.episode.name,
            size: episode.episode.size,
            url: episode.localPath!,
          ),
        )
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
  }
}
