import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

/// The directory comes from the native IO adapter: Dart prefetch and player
/// reads must share an exact on-disk namespace, not two unrelated caches.
class PlaybackMediaCache {
  static const _channel = MethodChannel('shortplay/native_player');
  static Future<MediaDownloader?>? _instance;
  static MediaDownloader? _ready;

  /// Selection may use already-open media storage without waiting on a new
  /// platform call or delaying a cold playback request.
  static MediaDownloader? get ready => _ready;

  static Future<MediaDownloader?> get instance => _instance ??= _open();

  static Future<MediaDownloader?> _open() async {
    try {
      final path = await _channel.invokeMethod<String>('mediaCacheDirectory');
      if (path == null || path.isEmpty) return null;
      return _ready = MediaDownloader(MediaCacheStore(Directory(path)));
    } on MissingPluginException {
      return null;
    } catch (error) {
      debugPrint('[PlaybackSDK] 媒体缓存不可用，使用原网络读取: $error');
      return null;
    }
  }
}
