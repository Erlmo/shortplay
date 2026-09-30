import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shortplay/models/episode.dart';
import 'package:shortplay/pages/cache_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/download_service.dart';
import 'package:shortplay/services/offline_playback_cache.dart';

class _Request {
  _Request(this.url, this.path);
  final String url;
  final String path;
  final Completer<int> result = Completer<int>();

  void finish({int status = 0, List<int>? bytes = const [1, 2, 3, 4]}) {
    if (bytes != null) {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
    }
    result.complete(status);
  }
}

class _Downloader {
  final List<_Request> requests = [];
  Future<int> call(String url, String key, String path) {
    final request = _Request(url, path);
    requests.add(request);
    return request.result.future;
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待缓存状态超时');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Episode _episode(int index, {String? url}) =>
    Episode(index: index, name: '第$index集', size: 0, url: url ?? 'video$index');

Future<DownloadResolveResult> _resolve(Episode ep) async =>
    DownloadResolveResult(cdnUrl: ep.url, keyHex: 'test-key');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Downloader downloader;
  late SharedPreferences prefs;
  final services = <DownloadService>[];
  final clients = <ApiClient>[];

  DownloadService createService({DecryptFile? decrypt}) {
    final client = ApiClient();
    clients.add(client);
    final service = DownloadService(
      apiClient: client,
      documentsDirectory: () async => directory,
      preferences: () async => prefs,
      decryptToFile: decrypt ?? downloader.call,
      retryDelay: Duration.zero,
    );
    services.add(service);
    return service;
  }

  Future<int> add(DownloadService service, String id, List<Episode> episodes,
          {DownloadResolver? resolver}) =>
      service.addDownloads(
        dramaId: id,
        dramaName: id,
        episodes: episodes,
        resolveUrl: resolver ?? _resolve,
      );

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('shortplay-cache-test-');
    downloader = _Downloader();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    for (final request in downloader.requests) {
      if (!request.result.isCompleted) request.finish(status: 1, bytes: null);
    }
    // 让已取消的 native 替身回调完成并清理各自的临时文件。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final client in clients) {
      client.dio.close(force: true);
    }
    clients.clear();
    directory.deleteSync(recursive: true);
  });

  test('空列表和无效集号不创建缓存组，空组不能完成', () async {
    final service = createService();
    await expectLater(add(service, 'a', []), throwsA(isA<ApiException>()));
    await expectLater(
        add(service, 'a', [_episode(0)]), throwsA(isA<ApiException>()));
    await expectLater(add(service, 'a', [_episode(1, url: '')]),
        throwsA(isA<ApiException>()));
    expect(service.groups, isEmpty);
    expect(
        DramaDownloadGroup(dramaId: 'a', dramaName: 'a', episodes: [])
            .isAllCompleted,
        isFalse);
    expect(downloader.requests, isEmpty);
  });

  test('新任务立即持久化，重复点击不重复入队且返回真实集数', () async {
    final service = createService();
    expect(await add(service, 'a', [_episode(1), _episode(1), _episode(2)]), 2);
    expect(await add(service, 'a', [_episode(1), _episode(2)]), 0);
    await _until(() => downloader.requests.length == 2);
    expect(service.groups['a']!.totalCount, 2);
    final state = jsonDecode(prefs.getString('download_state_v3')!) as Map;
    expect((state['groups'] as List).single['episodes'], hasLength(2));
    expect(service.groups['a']!.isAllCompleted, isFalse);
    for (final request in downloader.requests) {
      request.finish();
    }
    await _until(() => service.groups['a']!.isAllCompleted);
    expect(await add(service, 'a', [_episode(1), _episode(2)]), 0);
  });

  test('同集号对应不同视频时拒绝整个请求，避免静默漏集', () async {
    final service = createService();
    await expectLater(
        add(service, 'a', [_episode(1), _episode(1, url: 'other')]),
        throwsA(isA<ApiException>()));
    expect(service.groups, isEmpty);
  });

  test('全局三并发释放后自动下载其他剧并保留各自解析器', () async {
    final service = createService();
    await add(service, 'a', [_episode(1), _episode(2), _episode(3)]);
    await _until(() => downloader.requests.length == 3);
    await add(service, 'b', [_episode(1)],
        resolver: (ep) async =>
            const DownloadResolveResult(cdnUrl: 'group-b', keyHex: 'key-b'));
    expect(downloader.requests, hasLength(3));
    downloader.requests.first.finish();
    await _until(() => downloader.requests.length == 4);
    expect(downloader.requests.last.url, 'group-b');
    expect(
        downloader.requests.where((r) => !r.result.isCompleted), hasLength(3));
  });

  test('native 返回成功但空文件或无文件时重试并失败，不能虚报完成', () async {
    for (final bytes in <List<int>?>[null, []]) {
      int attempts = 0;
      final service = createService(decrypt: (url, key, path) async {
        attempts++;
        if (bytes != null) File(path).writeAsBytesSync(bytes);
        return 0;
      });
      final id = bytes == null ? 'missing' : 'empty';
      await add(service, id, [_episode(1)]);
      await _until(() =>
          service.groups[id]!.episodes.single.status == DownloadStatus.failed);
      expect(attempts, 3);
      expect(service.groups[id]!.completedCount, 0);
      expect(service.groups[id]!.episodes.single.error, contains('有效文件'));
      expect(File('${directory.path}/downloads/$id/ep_1.mp4').existsSync(),
          isFalse);
    }
  });

  test('下载只暴露校验后的正式文件并可恢复离线播放', () async {
    final service = createService();
    await add(service, 'a', [_episode(1)]);
    await _until(() => downloader.requests.length == 1);
    expect(downloader.requests.single.path, endsWith('.part'));
    expect(
        OfflinePlaybackCache.completedEpisodesFromGroup(service.groups['a']!),
        isEmpty);
    downloader.requests.single.finish();
    await _until(() => service.groups['a']!.isAllCompleted);
    await service.saveState();
    expect(File(downloader.requests.single.path).existsSync(), isFalse);
    final restored = createService();
    await restored.ensureLoaded();
    final offline =
        OfflinePlaybackCache.completedEpisodesFromGroup(restored.groups['a']!);
    expect(offline.single.index, 1);
    expect(File(offline.single.url).lengthSync(), 4);
    expect(restored.groups['a']!.episodes.single.progress, 1);
  });

  test('暂停解析中的任务不进入 native，继续后重新执行', () async {
    final resolveGate = Completer<DownloadResolveResult>();
    int resolves = 0;
    final service = createService();
    await add(service, 'a', [_episode(1)], resolver: (ep) {
      resolves++;
      return resolves == 1 ? resolveGate.future : _resolve(ep);
    });
    final dl = service.groups['a']!.episodes.single;
    service.pauseEpisode(dl);
    resolveGate.complete(await _resolve(dl.episode));
    await service.saveState();
    expect(dl.status, DownloadStatus.paused);
    expect(downloader.requests, isEmpty);
    service.resumeEpisode(dl);
    await _until(() => downloader.requests.length == 1);
    downloader.requests.single.finish();
    await _until(() => dl.isPlayable);
    expect(resolves, 2);
  });

  test('native 下载期间暂停再继续不会重复占用同集，旧结果不能提交', () async {
    final service = createService();
    await add(service, 'a', [_episode(1)]);
    await _until(() => downloader.requests.length == 1);
    final dl = service.groups['a']!.episodes.single;
    service.pauseEpisode(dl);
    service.resumeEpisode(dl);
    await service.saveState();
    expect(downloader.requests, hasLength(1));
    downloader.requests.first.finish();
    await _until(() => downloader.requests.length == 2);
    expect(dl.isPlayable, isFalse);
    expect(File(downloader.requests.first.path).existsSync(), isFalse);
    downloader.requests.last.finish(bytes: [5, 6]);
    await _until(() => dl.isPlayable);
    expect(File(dl.localPath!).readAsBytesSync(), [5, 6]);
  });

  test('失败可直接重试，暂停整组后不启动后续集', () async {
    final service = createService();
    await add(
        service, 'a', [_episode(1), _episode(2), _episode(3), _episode(4)]);
    await _until(() => downloader.requests.length == 3);
    service.pauseGroup('a');
    for (final request in downloader.requests) {
      request.finish(status: 2);
    }
    await _until(
        () => downloader.requests.every((r) => !File(r.path).existsSync()));
    expect(service.isGroupPaused('a'), isTrue);
    expect(downloader.requests, hasLength(3));
    service.resumeGroup('a');
    await _until(() => downloader.requests.length == 6);
    expect(service.isGroupPaused('a'), isFalse);
  });

  test('删除后重新添加同剧，旧任务迟到不能覆盖新文件或复活记录', () async {
    final service = createService();
    await add(service, 'a', [_episode(1)]);
    await _until(() => downloader.requests.length == 1);
    final old = downloader.requests.single;
    await service.deleteGroup('a');
    expect(service.groups, isEmpty);
    await add(service, 'a', [_episode(1)]);
    await _until(() => downloader.requests.length == 2);
    final current = downloader.requests.last;
    expect(old.path, isNot(current.path));
    current.finish(bytes: [7, 8, 9]);
    await _until(() => service.groups['a']!.isAllCompleted);
    old.finish(bytes: [1]);
    await _until(() => !File(old.path).existsSync());
    final dl = service.groups['a']!.episodes.single;
    expect(File(dl.localPath!).readAsBytesSync(), [7, 8, 9]);
    await service.deleteGroup('a');
    final restored = createService();
    await restored.ensureLoaded();
    expect(restored.groups, isEmpty);
  });

  test('缓存文件被截断或删除后变成可重试失败，不再计入完成', () async {
    final service = createService();
    await add(service, 'a', [_episode(1), _episode(2)]);
    await _until(() => downloader.requests.length == 2);
    for (final request in downloader.requests) {
      request.finish();
    }
    await _until(() => service.groups['a']!.isAllCompleted);
    final episodes = service.groups['a']!.episodes;
    File(episodes.first.localPath!).writeAsBytesSync([1]);
    File(episodes.last.localPath!).deleteSync();
    expect(service.groups['a']!.completedCount, 0);
    expect(
        OfflinePlaybackCache.completedEpisodesFromGroup(service.groups['a']!),
        isEmpty);
    await service.refreshFiles();
    expect(episodes.every((e) => e.status == DownloadStatus.failed), isTrue);
    service.resumeGroup('a');
    await _until(() => downloader.requests.length == 4);
  });

  test('旧版缓存迁移保留有效文件，清除空组并隔离损坏记录', () async {
    final file = File('${directory.path}/downloads/a/ep_1.mp4');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([1, 2]);
    File('${file.parent.path}/interrupted.part').writeAsBytesSync([3]);
    await prefs.setStringList('download_completed_keys', ['a_1', 'a_2']);
    await prefs.setStringList('download_groups_v2', [
      'not-json',
      jsonEncode({'dramaId': 'empty', 'dramaName': '空', 'episodes': []}),
      jsonEncode({
        'dramaId': 'a',
        'dramaName': 'a',
        'episodes': [
          {'index': 1, 'name': '一', 'url': 'v1'},
          {'index': 2, 'name': '二', 'url': 'v2'},
          {'index': 3, 'name': '三', 'url': 'v3'},
          null,
        ]
      }),
    ]);
    final service = createService();
    await service.ensureLoaded();
    expect(service.groups.keys, ['a']);
    expect(service.groups['a']!.completedCount, 1);
    expect(service.groups['a']!.episodes[1].status, DownloadStatus.failed);
    expect(service.groups['a']!.episodes[2].status, DownloadStatus.paused);
    expect(prefs.getString('download_state_v3'), isNotNull);
    expect(File('${file.parent.path}/interrupted.part').existsSync(), isFalse);
    await service.deleteGroup('a');
    final restored = createService();
    await restored.ensureLoaded();
    expect(restored.groups, isEmpty); // 不会从保留的旧版记录再次复活。
  });

  test('加载失败会结束等待且不覆盖损坏快照', () async {
    await prefs.setString('download_state_v3', 'broken-json');
    final service = createService();
    await expectLater(
        service.ensureLoaded().timeout(const Duration(seconds: 1)),
        throwsA(isA<ApiException>()));
    expect(service.loaded, isTrue);
    expect(service.lastError, contains('读取缓存失败'));
    expect(prefs.getString('download_state_v3'), 'broken-json');
  });

  test('解析抛出 Error 也释放并发槽并允许用户重试', () async {
    final service = createService();
    await add(service, 'a', [_episode(1)],
        resolver: (_) async => throw StateError('bad resolver'));
    final dl = service.groups['a']!.episodes.single;
    await _until(() => dl.status == DownloadStatus.failed);
    service.retryFailed('a', _resolve);
    await _until(() => downloader.requests.length == 1);
    downloader.requests.single.finish();
    await _until(() => dl.isPlayable);
  });

  test('重启后中断的任务暂停等待用户继续，不误报完成', () async {
    final service = createService();
    await add(
        service, 'a', [_episode(1), _episode(2), _episode(3), _episode(4)]);
    await _until(() => downloader.requests.length == 3);
    await service.saveState();
    final restored = createService();
    await restored.ensureLoaded();
    expect(restored.groups['a']!.completedCount, 0);
    expect(
        restored.groups['a']!.episodes
            .every((e) => e.status == DownloadStatus.paused),
        isTrue);
  });

  testWidgets('缓存页零完成时展示真实总数，暂停继续后才显示完成', (tester) async {
    late DownloadService service;
    await tester.runAsync(() async {
      service = createService();
      await add(service, 'a', [_episode(1), _episode(2), _episode(3)]);
      await _until(() => downloader.requests.length == 3);
    });
    // 文件服务在真实异步区域运行；同时推进 Widget 测试的虚拟时钟。
    Future<void> settleService(bool Function() condition) async {
      for (int i = 0; i < 100 && !condition(); i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    await tester.pumpWidget(MaterialApp(
        home: CachePage(
      downloadService: service,
      apiClient: service.apiClient,
    )));
    await tester.pump();
    expect(find.text('已缓存 0 / 3 集'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
    await tester.tap(find.text('暂停下载'));
    await tester.pumpAndSettle();
    expect(service.isGroupPaused('a'), isTrue);
    await tester.tap(find.text('继续 / 重试'));
    await tester.pump();
    expect(
        service.groups['a']!.episodes
            .every((e) => e.status == DownloadStatus.pending),
        isTrue);
    for (final request in downloader.requests.toList()) {
      request.finish();
    }
    await settleService(() => downloader.requests.length == 6);
    for (final request in downloader.requests.skip(3)) {
      request.finish();
    }
    await settleService(() => service.groups['a']!.isAllCompleted);
    await tester.pumpAndSettle();
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('共 3 集'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('标题没有数字时预加载、播放与缓存仍生成一致的非零集号', () {
    final result = TheaterEpisodesResult(allItemIds: [
      'a',
      'b'
    ], chapters: [
      TheaterChapter(itemId: 'a', title: '初遇', realChapterOrder: '0'),
      TheaterChapter(itemId: 'b', title: '再遇', realChapterOrder: '0'),
    ]);
    expect(result.toEpisodes().map((e) => e.index), [1, 2]);
    expect(result.toEpisodes().map((e) => e.url), ['a', 'b']);
  });
}
