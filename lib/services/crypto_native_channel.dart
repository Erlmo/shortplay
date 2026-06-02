import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges Dart to the native "crypto://" libmpv protocol.
///
/// The native core (`libshortplay_crypto.so`) registers a custom libmpv
/// stream protocol that decrypts standard MP4 CENC (AES-128 CTR) on the fly,
/// inside the player's IO pipeline — replacing the old localhost HTTP proxy.
///
/// Usage per Player instance:
/// ```dart
/// final player = Player();
/// final handle = await player.handle;            // mpv pointer
/// await CryptoNativeChannel.instance.registerCryptoProtocol(handle);
/// await player.open(Media(CryptoNativeChannel.buildCryptoUrl(cdnUrl, keyHex)));
/// ```
class CryptoNativeChannel {
  CryptoNativeChannel._();
  static final CryptoNativeChannel instance = CryptoNativeChannel._();

  static const MethodChannel _channel = MethodChannel('shortplay/crypto');

  /// Whether native crypto is supported on this platform.
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Build the URL handed to media_kit for native decryption:
  /// `crypto://<percent-encoded-cdn-url>?key=<32 hex chars>`.
  ///
  /// Mirrors the native `parse_uri` in crypto_stream.c: everything before
  /// `?key=` is the percent-encoded CDN url, followed by 32 hex key chars.
  static String buildCryptoUrl(String cdnUrl, String keyHex) {
    final encoded = Uri.encodeComponent(cdnUrl);
    return 'crypto://$encoded?key=$keyHex';
  }

  /// Register the "crypto://" protocol on the given mpv [handle]
  /// (from `await player.handle`). Must be called once per Player instance,
  /// before `player.open(...)`.
  ///
  /// Returns the native status: 0 == success; non-zero == failure
  /// (1 bad handle, 2 libmpv symbol missing, other = mpv error). Returns a
  /// negative value if the platform call itself failed.
  Future<int> registerCryptoProtocol(int handle) async {
    if (!isSupported) return -1;
    try {
      final status = await _channel.invokeMethod<int>(
        'registerCryptoProtocol',
        {'handle': handle},
      );
      final code = status ?? -1;
      if (code != 0) {
        debugPrint('registerCryptoProtocol 返回非零状态: $code');
      }
      return code;
    } on PlatformException catch (e) {
      debugPrint('registerCryptoProtocol 平台异常: ${e.code} ${e.message}');
      return -1;
    } catch (e) {
      debugPrint('registerCryptoProtocol 失败: $e');
      return -1;
    }
  }

  /// Prewarm the native cache for [cdnUrl] so the next playback of it skips the
  /// ~300-680ms box scan + header fetch + sample parse. Fire-and-forget from
  /// the caller's perspective; runs on a background thread natively.
  ///
  /// Returns 0 on success / already-cached, non-zero on failure, or -1 if the
  /// platform isn't supported or the call itself failed.
  Future<int> prewarm(String cdnUrl, String keyHex) async {
    if (!isSupported) return -1;
    try {
      final status = await _channel.invokeMethod<int>(
        'prewarm',
        {'url': cdnUrl, 'key': keyHex},
      );
      return status ?? -1;
    } on PlatformException catch (e) {
      debugPrint('prewarm 平台异常: ${e.code} ${e.message}');
      return -1;
    } catch (e) {
      debugPrint('prewarm 失败: $e');
      return -1;
    }
  }

  Future<int> prewarmHeaderOnly(String cdnUrl, String keyHex) async {
    if (!isSupported) return -1;
    try {
      final status = await _channel.invokeMethod<int>(
        'prewarmHeaderOnly',
        {'url': cdnUrl, 'key': keyHex},
      );
      return status ?? -1;
    } on PlatformException catch (e) {
      debugPrint('prewarmHeaderOnly 平台异常: ${e.code} ${e.message}');
      return -1;
    } catch (e) {
      debugPrint('prewarmHeaderOnly 失败: $e');
      return -1;
    }
  }

  Future<int> prewarmSeedMdat(String cdnUrl) async {
    if (!isSupported) return -1;
    try {
      final status = await _channel.invokeMethod<int>(
        'prewarmSeedMdat',
        {'url': cdnUrl},
      );
      return status ?? -1;
    } on PlatformException catch (e) {
      debugPrint('prewarmSeedMdat 平台异常: ${e.code} ${e.message}');
      return -1;
    } catch (e) {
      debugPrint('prewarmSeedMdat 失败: $e');
      return -1;
    }
  }

  /// Decrypt the entire encrypted MP4 at [cdnUrl] using [keyHex] and write the
  /// resulting clear MP4 to [outputPath]. Blocking (downloads + decrypts the
  /// full file). Returns 0 on success, non-zero on failure.
  Future<int> decryptToFile(String cdnUrl, String keyHex, String outputPath) async {
    if (!isSupported) return -1;
    try {
      final status = await _channel.invokeMethod<int>(
        'decryptToFile',
        {'url': cdnUrl, 'key': keyHex, 'outputPath': outputPath},
      );
      return status ?? -1;
    } on PlatformException catch (e) {
      debugPrint('decryptToFile 平台异常: ${e.code} ${e.message}');
      return -1;
    } catch (e) {
      debugPrint('decryptToFile 失败: $e');
      return -1;
    }
  }
}
