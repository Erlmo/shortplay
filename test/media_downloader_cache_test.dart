import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

void main() {
  late Directory directory;
  late MediaCacheStore cache;
  late MediaDownloader downloader;
  late HttpServer server;
  late Uint8List media;
  late List<String> ranges;
  late List<String?> encodings;
  late Completer<void> firstRequest;
  var slow = false;
  var truncateFirst = false;
  var wrongRange = false;
  var ignoreRange = false;
  var requests = 0;
  var shortWindows = false;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('shortplay-media-test-');
    cache = MediaCacheStore(directory);
    downloader =
        MediaDownloader(cache, readTimeout: const Duration(seconds: 2));
    media =
        Uint8List.fromList(List.generate(200000, (i) => (i * 17 + 9) % 251));
    ranges = [];
    encodings = [];
    firstRequest = Completer<void>();
    slow = false;
    truncateFirst = false;
    wrongRange = false;
    ignoreRange = false;
    requests = 0;
    shortWindows = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      final number = requests;
      final value = request.headers.value(HttpHeaders.rangeHeader) ??
          'bytes=0-${media.length - 1}';
      ranges.add(value);
      encodings.add(request.headers.value(HttpHeaders.acceptEncodingHeader));
      if (!firstRequest.isCompleted) firstRequest.complete();
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(value)!;
      final start = int.parse(match[1]!);
      final end = math.min(math.min(int.parse(match[2]!), media.length - 1),
          shortWindows ? start + 19999 : media.length - 1);
      try {
        if (truncateFirst && number == 1) {
          final socket =
              await request.response.detachSocket(writeHeaders: false);
          socket.write(
              'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes $start-$end/${media.length}\r\nContent-Length: ${end - start + 1}\r\nETag: "sample"\r\nConnection: close\r\n\r\n');
          socket.add(media.sublist(start, math.min(start + 40000, end + 1)));
          await socket.flush();
          await socket.close();
          return;
        }
        final offset = ignoreRange ? 0 : start;
        final last = ignoreRange ? media.length - 1 : end;
        request.response.statusCode = ignoreRange ? 200 : 206;
        request.response.headers.set(HttpHeaders.etagHeader, '"sample"');
        if (!ignoreRange) {
          request.response.headers.set(HttpHeaders.contentRangeHeader,
              'bytes ${wrongRange ? start + 1 : start}-$end/${media.length}');
        }
        request.response.contentLength = last - offset + 1;
        for (var pos = offset; pos <= last; pos += 8192) {
          request.response
              .add(media.sublist(pos, math.min(pos + 8192, last + 1)));
          if (slow) {
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 8));
          }
        }
        await request.response.close();
      } on Object {/* Cancellation deliberately closes the client socket. */}
    });
  });
  tearDown(() async {
    downloader.close();
    await server.close(force: true);
    // A cache commit already handed to a worker may finish after cancellation.
    for (var n = 0; n < 10; n++) {
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  });
  String url([String suffix = 'sample']) =>
      'http://127.0.0.1:${server.port}/$suffix';

  test('合法短206窗口连续读取，不误报EOF且跨窗口缓存完整块', () async {
    shortWindows = true;
    final data = await downloader.readRange(url(), 0, 119999);
    expect(data.bytes, media.sublist(0, 120000));
    expect(cache.read(url(), 0, 98303), media.sublist(0, 98304));
    expect(ranges[1], startsWith('bytes=20000-'));
  });

  test('不支持Range的来源只返回即时字节，不发布缓存', () async {
    ignoreRange = true;
    final data = await downloader.readRange(url(), 0, 65535);
    expect(data.bytes, media.sublist(0, 65536));
    expect(data.rangeSupported, false);
    expect(cache.inspect(url()).cachedBytesFromZero, 0);
  });

  test('不支持Range的大文件仍可完整下载', () async {
    ignoreRange = true;
    media = Uint8List.fromList(List.generate(1500000, (i) => i % 251));
    final output = File('${directory.path}/complete.mp4');
    expect(await downloader.downloadToFile(url(), output), media.length);
    expect(sha256.convert(output.readAsBytesSync()), sha256.convert(media));
    expect(cache.inspect(url()).cachedBytesFromZero, 0);
  });

  test('媒体预取与重建缓存实例共享真实字节，不再请求网络', () async {
    final info = await downloader.prefetch(url(), bytes: 65536);
    expect(info.cachedBytesFromZero, 65536);
    expect(info.totalLength, media.length);
    expect(info.cachedBytes, 65536);
    expect(ranges, ['bytes=0-65535']);
    expect(encodings, ['identity']);
    final reopened = MediaCacheStore(directory);
    expect(reopened.read(url(), 100, 33000), media.sublist(100, 33001));
    final again = await downloader.readRange(url(), 0, 65535);
    expect(again.bytes, media.sublist(0, 65536));
    expect(requests, 1);
  });

  test('缺口只补缺失字节，已有缓存前缀不会重新下载', () async {
    await downloader.prefetch(url(), bytes: 65536);
    final data = await downloader.readRange(url(), 0, 131071);
    expect(data.bytes, media.sublist(0, 131072));
    expect(ranges, ['bytes=0-65535', 'bytes=65536-131071']);
    expect(cache.inspect(url()).cachedBytesFromZero, 131072);
  });

  test('短正文从实际已读偏移续传，不从零开始也不伪造EOF', () async {
    truncateFirst = true;
    final data = await downloader.readRange(url(), 0, 98303);
    expect(data.bytes, media.sublist(0, 98304));
    expect(ranges, ['bytes=0-98303', 'bytes=40000-98303']);
  });

  test('重叠请求共享在途下载，取消一个使用者不打断另一个', () async {
    slow = true;
    final cancelled = PlaybackCancellation();
    final one = downloader.readRange(url(), 0, 131071, cancellation: cancelled);
    final failed = expectLater(one, throwsA(isA<PlaybackCancelled>()));
    await firstRequest.future;
    final two = downloader.readRange(url(), 32768, 98303);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    cancelled.cancel();
    await failed;
    final result = await two;
    expect(result.bytes, media.sublist(32768, 98304));
    expect(requests, 1);
    expect(downloader.sharedTransfers, 1);
  });

  test('全部使用者取消会中止请求，缓存中不出现半块', () async {
    slow = true;
    final cancelled = PlaybackCancellation();
    final request =
        downloader.readRange(url(), 0, 199999, cancellation: cancelled);
    final failed = expectLater(request, throwsA(isA<PlaybackCancelled>()));
    await firstRequest.future;
    await Future<void>.delayed(const Duration(milliseconds: 45));
    cancelled.cancel();
    await failed;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final info = cache.inspect(url());
    expect(info.cachedBytesFromZero % MediaCacheStore.blockSize, 0);
    expect(info.cachedBytesFromZero, lessThan(media.length));
  });

  test('错误Content-Range不写缓存，且不会重试不合法响应', () async {
    wrongRange = true;
    await expectLater(downloader.readRange(url(), 0, 65535),
        throwsA(isA<MediaRangeException>()));
    expect(cache.inspect(url()).cachedBytes, 0);
    expect(requests, 1);
  });

  test('非零Range被忽略时拒绝数据，不把文件头当作后面的片段', () async {
    ignoreRange = true;
    await expectLater(downloader.readRange(url(), 65536, 98303),
        throwsA(isA<MediaRangeException>()));
    expect(cache.inspect(url()).cachedBytes, 0);
  });

  test('最后不足一块的有效EOF可以缓存，完整下载与原文hash一致', () async {
    final file = File('${directory.path}/output.part');
    final size = await downloader.downloadToFile(url(), file);
    expect(size, media.length);
    expect(sha256.convert(file.readAsBytesSync()), sha256.convert(media));
    expect(cache.inspect(url()).cachedBytesFromZero, media.length);
    final count = requests;
    final tail = await downloader.readRange(url(), 196608, 230000);
    expect(tail.bytes, media.sublist(196608));
    expect(requests, count);
  });

  test('校验和损坏返回miss，元数据过期重建时不复活旧尾块', () {
    final stamp = DateTime(2026, 11, 9);
    var now = stamp;
    final store = MediaCacheStore(directory, clock: () => now);
    final data = Uint8List.fromList(List.filled(65536, 7));
    store.write(url(), 0, data,
        totalLength: 65536, expiresAt: now.add(const Duration(seconds: 1)));
    final block = File(
        '${directory.path}/${MediaCacheStore.identity(url())}/blocks/0.blk');
    final bytes = block.readAsBytesSync();
    bytes[40] ^= 1;
    block.writeAsBytesSync(bytes);
    expect(store.read(url(), 0, 100), isNull);
    expect(store.corruptBlocks, 1);
    now = now.add(const Duration(seconds: 2));
    store.write(url(), 0, data.sublist(0, 32768), totalLength: 65536);
    expect(store.read(url(), 32768, 65535), isNull);
    expect(store.inspect(url()).cachedBytesFromZero, 32768);
  });

  test('磁盘预算与LRU按实际读取更新，只淘汰专属缓存块', () {
    var now = DateTime(2026, 11, 9);
    final store = MediaCacheStore(directory, maxBytes: 66000, clock: () => now);
    final data = Uint8List.fromList(List.filled(32768, 5));
    store.write(url('a'), 0, data, totalLength: data.length);
    now = now.add(const Duration(seconds: 1));
    store.write(url('b'), 0, data, totalLength: data.length);
    now = now.add(const Duration(seconds: 1));
    expect(store.read(url('a'), 0, 3), isNotNull);
    now = now.add(const Duration(seconds: 1));
    store.write(url('c'), 0, data, totalLength: data.length);
    expect(store.read(url('a'), 0, 3), isNotNull);
    expect(store.read(url('b'), 0, 3), isNull);
  });
}
