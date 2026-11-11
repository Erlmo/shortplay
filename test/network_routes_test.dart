import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late MediaDownloader downloader;
  late MediaCacheStore cache;
  late Uint8List media;
  late List<(String, int)> requests;
  late Completer<void> opened;
  var mode = 'ok';
  String url(String path) => 'http://127.0.0.1:${server.port}/$path';
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('network-routes-');
    cache = MediaCacheStore(directory);
    downloader =
        MediaDownloader(cache, readTimeout: const Duration(seconds: 2));
    media = Uint8List.fromList(List.generate(180000, (i) => (i * 19) % 251));
    requests = [];
    opened = Completer<void>();
    mode = 'ok';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      final range = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers.value('range') ?? '');
      final start = range == null ? 0 : int.parse(range[1]!);
      final end = range == null
          ? media.length - 1
          : math.min(media.length - 1, int.parse(range[2]!));
      requests.add((path, start));
      if (!opened.isCompleted) opened.complete();
      try {
        if (mode == 'hang') {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        if (mode == 'noRange' && path == '/main' && range == null) {
          request.response.statusCode = 503;
          await request.response.close();
          return;
        }
        if (mode == 'all403' ||
            (path == '/main' &&
                ['403', 'different', 'fail', 'hang'].contains(mode))) {
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        request.response.statusCode = mode == 'noRange' ? 200 : 206;
        if (mode != 'noRange') {
          request.response.headers.set('Content-Range',
              'bytes ${mode == 'badRange' ? start + 1 : start}-$end/${media.length}');
        }
        request.response.headers
            .set('ETag', path == '/main' ? '"primary"' : '"secondary"');
        final bodyStart = mode == 'noRange' ? 0 : start;
        final bodyEnd = mode == 'noRange' ? media.length - 1 : end;
        request.response.contentLength = bodyEnd - bodyStart + 1;
        final bytes = Uint8List.fromList(media.sublist(bodyStart, bodyEnd + 1));
        if (mode == 'different' && path == '/backup') bytes[0] ^= 0xff;
        request.response.add(bytes);
        await request.response.close();
      } catch (_) {/* Cancellation closes the socket. */}
    });
  });
  tearDown(() async {
    downloader.close();
    await server.close(force: true);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  test('主CDN403只访问一次，切同流backup并保留物理URL缓存隔离', () async {
    mode = '403';
    downloader.registerSource(url('main'), [url('backup')]);
    final result = await downloader.readRange(url('main'), 0, 65535);
    expect(result.bytes, media.sublist(0, 65536));
    expect(requests, [('/main', 0), ('/backup', 0)]);
    expect(downloader.activeSourceUrl(url('main')), url('backup'));
    expect(cache.inspect(url('main')).cachedBytesFromZero, 0);
    expect(cache.inspect(url('backup')).cachedBytesFromZero, 65536);
    await downloader.readRange(url('main'), 0, 65535);
    expect(requests, hasLength(2));
  });
  test('已交付后切CDN校验前缀和总长，不同ETag但同内容可以续读', () async {
    downloader.registerSource(url('main'), [url('backup')]);
    final first = await downloader.readRange(url('main'), 0, 65535);
    mode = 'fail';
    final next = await downloader.readRange(url('main'), 65536, 119999);
    expect([...first.bytes, ...next.bytes], media.sublist(0, 120000));
    expect(requests,
        [('/main', 0), ('/main', 65536), ('/backup', 0), ('/backup', 65536)]);
    expect(cache.read(url('main'), 65536, 98303), isNull);
  });
  test('候选前缀不一致拒绝中途切换，不把坏数据交给播放器', () async {
    downloader.registerSource(url('main'), [url('backup')]);
    await downloader.readRange(url('main'), 0, 65535);
    mode = 'different';
    await expectLater(downloader.readRange(url('main'), 65536, 119999),
        throwsA(isA<MediaRangeException>()));
    expect(requests.where((r) => r.$1 == '/backup').toList(), [('/backup', 0)]);
    expect(cache.metadata(url('backup')), isNull);
  });
  test('协议错误不当网络错误切CDN，单URL403不无限重试', () async {
    downloader.registerSource(url('main'), [url('backup')]);
    mode = 'badRange';
    await expectLater(downloader.readRange(url('main'), 0, 65535),
        throwsA(isA<MediaRangeException>()));
    expect(requests, [('/main', 0)]);
    requests.clear();
    mode = 'all403';
    await expectLater(downloader.readRange(url('single'), 0, 65535),
        throwsA(isA<MediaRangeException>()));
    expect(requests, [('/single', 0)]);
  });
  test('全部候选失败仅遍历一次，不生成新域名', () async {
    mode = 'all403';
    downloader.registerSource(url('main'), [url('backup'), url('third')]);
    await expectLater(downloader.readRange(url('main'), 0, 65535),
        throwsA(isA<MediaRangeException>()));
    expect(requests.map((r) => r.$1), ['/main', '/backup', '/third']);
  });
  test('取消等待中的请求后不继续请求备用CDN', () async {
    mode = 'hang';
    downloader.registerSource(url('main'), [url('backup')]);
    final token = PlaybackCancellation();
    final future =
        downloader.readRange(url('main'), 0, 65535, cancellation: token);
    final assertion = expectLater(future, throwsA(isA<PlaybackCancelled>()));
    await opened.future;
    token.cancel();
    await assertion;
    expect(requests, [('/main', 0)]);
  });
  test('过期候选不联网，候选过滤并保持同条目顺序', () async {
    downloader.registerSource(url('main'), [url('backup')],
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)));
    await expectLater(
        downloader.readRange(url('main'), 0, 65535), throwsStateError);
    expect(requests, isEmpty);
    expect(
        mediaCandidateUrls(url('main'), [
          url('main'),
          'file:///x',
          'http://user:pass@example.com/x',
          url('backup')
        ]),
        [url('main'), url('backup')]);
  });
  test('不支持Range的下载可安全重启完整临时文件并切换备用', () async {
    mode = 'noRange';
    media = Uint8List.fromList(List.generate(1500000, (i) => (i * 19) % 251));
    downloader.registerSource(url('main'), [url('backup')]);
    final file = File('${directory.path}/full.mp4');
    expect(await downloader.downloadToFile(url('main'), file), media.length);
    expect(await file.readAsBytes(), media);
    expect(downloader.activeSourceUrl(url('main')), url('backup'));
  });

  test('模型仅解析同条目显式backup，兼容明文及base64字段', () {
    final item = FqVideoItem.fromJson({
      'main_url': base64Encode(utf8.encode('https://main.example/file.mp4')),
      'backup_url_1':
          base64Encode(utf8.encode('https://backup.example/file.mp4')),
      'backup_url_2': 'file:///bad',
      'backup_url_3': 'https://third.example/file.mp4',
      'codec_type': 'hevc',
      'definition': '720p',
    });
    expect(item.backupUrls,
        ['https://backup.example/file.mp4', 'https://third.example/file.mp4']);
    final nested = FqVideoItem.fromJson({
      'main_url': 'https://a.example/v.mp4',
      'video_meta': {'definition': '1080p'},
      'backup_url': 'https://b.example/v.mp4'
    });
    expect(nested.backupUrls, ['https://b.example/v.mp4']);
  });
}
