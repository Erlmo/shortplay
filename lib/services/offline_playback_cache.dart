import 'dart:io';

import '../models/episode.dart';
import 'download_service.dart';

class OfflinePlaybackCache {
  static List<Episode> completedEpisodesFromGroup(DramaDownloadGroup group) {
    return group.episodes
        .where(
          (episode) =>
              episode.status == DownloadStatus.completed &&
              episode.localPath != null &&
              File(episode.localPath!).existsSync(),
        )
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
