import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/services/native_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shortplay/native_player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.macOS
  ]) {
    test('$platform 仅在原生确认解码能力后开放BVC2', () async {
      debugDefaultTargetPlatformOverride = platform;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'supportsBvc2');
        return true;
      });
      expect(await NativePlayer.supportsByteVc2(), isTrue);
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      expect(await NativePlayer.supportsByteVc2(), isFalse);
    });
  }

  test('原生插件缺失时不宣告支持BVC2', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(
        channel, (_) async => throw MissingPluginException());
    expect(await NativePlayer.supportsByteVc2(), isFalse);
  });
}
