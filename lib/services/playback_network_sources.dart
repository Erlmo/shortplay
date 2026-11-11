import 'package:flutter/services.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

import '../models/fq_video.dart';
import 'playback_media_cache.dart';

/// Register before prewarm, file download or player creation. Raw media routes
/// are shared by native callbacks without changing the existing crypto ABI.
class PlaybackNetworkSources {
  static const _channel = MethodChannel('shortplay/native_player');

  static Future<void> configure(FqVideoItem item) async {
    final urls = mediaCandidateUrls(item.url, item.backupUrls);
    final expiry = item.expiresAt?.subtract(const Duration(seconds: 30));
    final downloader = await PlaybackMediaCache.instance;
    downloader?.registerSource(item.url, urls, expiresAt: expiry);
    try {
      await _channel.invokeMethod('registerMediaSource', {
        'primaryUrl': item.url,
        'urls': urls,
        'expiresAt': expiry?.millisecondsSinceEpoch,
      });
    } on MissingPluginException {
      // Older hosts retain the single-URL behaviour without a new dependency.
    }
  }
}
