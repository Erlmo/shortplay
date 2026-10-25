import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../models/episode.dart';
import '../models/playback_record.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/offline_playback_cache.dart';
import 'player_page.dart';

/// 从一条播放记录续播：定位到记录的那一集和进度；这部剧有已下载完成的
/// 剧集时优先离线播放。历史页和首页“继续观看”共用。
Future<void> openPlaybackRecord(
  BuildContext context, {
  required PlaybackRecord record,
  required ApiClient apiClient,
  DownloadService? downloadService,
}) {
  final drama = Drama(
    id: record.dramaId,
    name: record.dramaName,
    actors: '',
    cover: record.cover,
    intro: '',
    tags: const [],
    status: '',
    updateTime: '',
    isTheaterResource: record.dramaId != 0,
  );

  // 检查是否有本地缓存
  List<Episode>? offlineEpisodes;
  final group = downloadService?.groups[record.dramaId.toString()];
  if (group != null) {
    final completed = OfflinePlaybackCache.completedEpisodesFromGroup(group);
    if (completed.isNotEmpty) offlineEpisodes = completed;
  }

  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerPage(
        drama: drama,
        apiClient: apiClient,
        downloadService: downloadService,
        initialEpisodeIndex: record.episodeIndex,
        initialEpisodeNumber: record.episodeNumber,
        initialPositionMs: record.positionMs,
        offlineEpisodes: offlineEpisodes,
      ),
    ),
  );
}
