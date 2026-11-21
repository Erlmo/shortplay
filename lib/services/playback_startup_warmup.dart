import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

import 'theater_video_preload_manager.dart';

/// 进播放页之前提前准备要播的那一集：解析播放地址，从头播时再预取开头数据。
///
/// 播放页拿同一个 [manager] 起播时直接命中解析结果和缓存，不用再等后端和网络。
/// 失败不影响播放，播放页会照常重新解析。
void warmUpEpisode(
  TheaterVideoPreloadManager manager,
  String videoId, {
  required int episodeIndex,
  required bool fromStart,
}) {
  final id = videoId.trim();
  if (id.isEmpty) return;
  unawaited(() async {
    try {
      await manager.resolvePlayUrl(id, episodeIndex: episodeIndex);
      if (fromStart) await manager.prefetchMedia(id, manager.beginWarmup(id));
    } on PlaybackCancelled {
      // 播放器已经开始加载这一集，提前下载让位。
    } catch (error) {
      debugPrint('[Playback] 提前准备第${episodeIndex + 1}集失败（播放页会重新解析）: $error');
    }
  }());
}
