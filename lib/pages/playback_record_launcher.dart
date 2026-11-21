import 'dart:async';

import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../models/episode.dart';
import '../models/playback_record.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/offline_playback_cache.dart';
import '../services/playback_startup_warmup.dart';
import '../services/theater_video_preload_manager.dart';
import 'player_page.dart';

/// 从一条播放记录续播：定位到记录的那一集和进度；这部剧有已下载完成的
/// 当前续播集已下载完成时优先离线播放。历史页和首页“继续观看”共用。
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
    final episodeNumber = record.episodeNumber ?? record.episodeIndex + 1;
    if (completed.any((episode) => episode.index == episodeNumber)) {
      offlineEpisodes = completed;
    }
  }

  // 在线续播：剧集列表和播放地址同时开始请求，不再一个等一个。
  Future<TheaterEpisodesResult>? episodes;
  TheaterVideoPreloadManager? preloads;
  final videoId = record.videoId;
  if (offlineEpisodes == null && drama.isTheaterResource) {
    episodes = apiClient.fetchTheaterEpisodes(record.dramaId.toString());
    // 失败由播放页处理（会重新请求），这里只防止未处理的异步错误。
    unawaited(
        episodes.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    if (videoId != null) {
      preloads = TheaterVideoPreloadManager(apiClient: apiClient);
      warmUpEpisode(preloads, videoId,
          episodeIndex: record.episodeIndex, fromStart: record.positionMs <= 0);
    }
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
        prefetchedEpisodes: episodes,
        preloadManager: preloads,
      ),
    ),
  );
}
