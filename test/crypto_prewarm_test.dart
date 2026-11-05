import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/crypto_native_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shortplay/crypto');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('详情页与播放页同时预热同一地址只执行一次，完成后允许再次检查原生缓存', () async {
    final gate = Completer<int>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return gate.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final a = CryptoNativeChannel.instance
        .prewarm('https://cdn.example/first.mp4', 'key');
    final b = CryptoNativeChannel.instance
        .prewarm('https://cdn.example/first.mp4', 'key');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    gate.complete(0);
    expect(await a, 0);
    expect(await b, 0);
    expect(
        await CryptoNativeChannel.instance
            .prewarm('https://cdn.example/first.mp4', 'key'),
        0);
    expect(calls, 2);
  });
}
