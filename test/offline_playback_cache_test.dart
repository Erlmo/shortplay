import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/offline_playback_cache.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('offline-file-'));
  tearDown(() => directory.deleteSync(recursive: true));

  test('本地缓存路径和file URI都能读取，中文空格和特殊字符正确转义', () async {
    final file = File('${directory.path}/第 3 集 #1.mp4');
    file.writeAsBytesSync([1, 2, 3]);
    for (final path in [file.path, file.uri.toString()]) {
      final result = await OfflinePlaybackCache.playableFileUri(path);
      expect(Uri.parse(result).scheme, 'file');
      expect(File.fromUri(Uri.parse(result)).path, file.path);
    }
  });

  test('丢失文件、空文件和目录立即报错，不交给播放器无限等待', () async {
    final empty = File('${directory.path}/empty.mp4')..createSync();
    for (final path in [
      '${directory.path}/missing.mp4',
      empty.path,
      directory.path
    ]) {
      await expectLater(OfflinePlaybackCache.playableFileUri(path),
          throwsA(isA<FileSystemException>()));
    }
  });

  test('离线播放拒绝网络URL和空路径', () async {
    for (final path in [
      '',
      'https://example.com/video.mp4',
      'crypto://video'
    ]) {
      await expectLater(OfflinePlaybackCache.playableFileUri(path),
          throwsA(isA<FileSystemException>()));
    }
  });
}
