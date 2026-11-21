import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/drama_season.dart';
import 'package:shortplay/models/episode.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/crypto_native_channel.dart';
import 'package:shortplay/services/download_service.dart';
import 'package:shortplay/services/native_player.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';

import 'support/video_resolution_adapter.dart';

class _Preloads extends TheaterVideoPreloadManager {
  _Preloads(ApiClient apiClient) : super(apiClient: apiClient);
  final resolved = <String>[];
  final full = <int>[];
  final headers = <int>[];
  @override
  Future<bool> preloadEpisodeHeaderOnly(
      {required List<Episode> episodes,
      required int currentIndex,
      required int targetIndex,
      required bool Function() isStillCurrent,
      PlaybackCancellation? cancellation}) async {
    headers.add(targetIndex);
    return true;
  }

  @override
  Future<String> resolvePlayUrl(String videoId,
      {required int episodeIndex,
      int maxRetries = 3,
      bool forPreload = false}) async {
    resolved.add(videoId);
    return CryptoNativeChannel.buildCryptoUrl(
        'https://cdn.example/$videoId.mp4', '0123456789abcdef0123456789abcdef');
  }

  @override
  Future<void> preloadEpisode(
      {required List<Episode> episodes,
      required int currentIndex,
      required int targetIndex,
      required bool Function() isStillCurrent,
      VoidCallback? onNextEpisodeReady,
      PlaybackCancellation? cancellation,
      int? prefetchBytes}) async {
    full.add(targetIndex);
    bytes.add(prefetchBytes);
    onNextEpisodeReady?.call();
  }

  final bytes = <int?>[];
}

class _CachedDownloads extends DownloadService {
  _CachedDownloads(ApiClient api, Directory directory, this.fixtureGroups)
      : super(
          apiClient: api,
          documentsDirectory: () async => directory,
          preferences: SharedPreferences.getInstance,
        );

  final Map<String, DramaDownloadGroup> fixtureGroups;
  @override
  Map<String, DramaDownloadGroup> get groups => fixtureGroups;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shortplay/native_player');
  const events = MethodChannel('shortplay/native_player/events');
  const crypto = MethodChannel('shortplay/crypto');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> emit(int id, String type, Object value) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope(
            {'playerId': id, 'type': type, 'value': value}),
        (_) => done.complete());
    await done.future;
  }

  for (final scenario in [
    for (final cached in [false, true])
      for (final start in [0, 45000])
        (
          cached: cached,
          start: start,
          swipe: false,
          stall: false,
          lifecycle: false,
          count: 3
        ),
    (
      cached: true,
      start: 0,
      swipe: true,
      stall: false,
      lifecycle: false,
      count: 3
    ),
    (
      cached: false,
      start: 0,
      swipe: false,
      stall: true,
      lifecycle: false,
      count: 3
    ),
    (
      cached: true,
      start: 0,
      swipe: false,
      stall: false,
      lifecycle: true,
      count: 3
    ),
    (
      cached: false,
      start: 0,
      swipe: false,
      stall: false,
      lifecycle: false,
      count: 5
    ),
  ]) {
    final cached = scenario.cached;
    final start = scenario.start;
    testWidgets(
        '从${start}ms起播，缓存=$cached，滑动=${scenario.swipe}，起播卡顿=${scenario.stall}，生命周期=${scenario.lifecycle}，共${scenario.count}集',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final adapter = VideoResolutionAdapter(
          reply: (_) =>
              resolutionJson({'code': 0, 'data': <String, dynamic>{}}));
      final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(api.dispose);
      final manager = _Preloads(api);
      final directory = Directory.systemTemp.createTempSync('cached-next-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final files = <int, File>{
        for (var n = 1; n <= 2; n++)
          n: File('${directory.path}/episode_$n.mp4')
            ..writeAsBytesSync([1, 2, 3]),
      };
      final downloads = _CachedDownloads(api, directory, {
        if (cached)
          '1234567890': DramaDownloadGroup(
            dramaId: '1234567890',
            dramaName: '首集测试',
            episodes: [
              for (var n = 1; n <= 2; n++)
                EpisodeDownload(
                  dramaId: '1234567890',
                  dramaName: '首集测试',
                  episode: Episode(index: n, name: '第$n集', size: 0, url: '$n'),
                  status: DownloadStatus.completed,
                  localPath: files[n]!.path,
                ),
            ],
          ),
      });
      await tester.runAsync(downloads.ensureLoaded);
      addTearDown(downloads.dispose);
      final createdUrls = <String>[];
      var nextId = 0;
      final nativeCalls = <(String, Object?)>[];
      final warmedUrls = <String>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(crypto, (call) async {
        if (call.method == 'prewarm') {
          warmedUrls.add((call.arguments as Map)['url'] as String);
        }
        return 0;
      });
      messenger.setMockMethodCallHandler(
          SystemChannels.platform, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add((call.method, call.arguments));
        if (call.method == 'create') {
          createdUrls.add((call.arguments as Map)['cdnUrl'] as String);
          final id = ++nextId;
          await emit(id, 'duration', 120000);
          if (id == 1 && scenario.stall) await emit(id, 'buffering', true);
          if (id == 1) await emit(id, 'firstFrame', true);
          return {'playerId': id, 'textureId': id};
        }
        if (call.method == 'prepareFirstFrame') {
          await emit((call.arguments as Map)['id'] as int, 'firstFrame', true);
        }
        if (call.method == 'play' || call.method == 'pause') {
          final id = (call.arguments as Map)['id'] as int;
          await emit(id, 'playing', call.method == 'play');
          // 新建后直接播放的播放器在播放时出首帧。
          if (call.method == 'play') await emit(id, 'firstFrame', true);
        }
        return null;
      });
      addTearDown(() async {
        await NativePlayer.resetEventListenerForTesting();
        for (final c in [channel, events, crypto, SystemChannels.platform]) {
          messenger.setMockMethodCallHandler(c, null);
        }
      });
      Future<void> settle() async {
        for (var n = 0; n < 4; n++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        await tester.pump();
      }

      List<String> callsOf(int id) => nativeCalls
          .where((c) => (c.$2 as Map?)?['id'] == id)
          .map((c) => c.$1)
          .toList();
      try {
        // Apple 保留起播预取；Android 仍在原生读取线程准备。
        if (!cached && start == 45000) {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        }
        await tester.pumpWidget(MaterialApp(
            home: PlayerPage(
          drama: Drama(
              id: 1234567890,
              name: '首集测试',
              actors: '',
              cover: '',
              intro: '',
              tags: const [],
              status: '',
              updateTime: ''),
          apiClient: api,
          downloadService: downloads,
          preloadManager: manager,
          initialPositionMs: start,
          seasons:
              const DramaSeasons(albumId: '', currentSeason: 1, seasons: []),
          prefetchedEpisodes: Future.value(TheaterEpisodesResult(allItemIds: [
            for (var n = 1; n <= scenario.count; n++) '$n'
          ], chapters: [
            for (var n = 1; n <= scenario.count; n++)
              TheaterChapter(
                  itemId: '$n', title: '第$n集', realChapterOrder: '$n'),
          ])),
        )));
        await settle();

        if (scenario.stall) {
          // 当前集卡顿时照常预渲染相邻集（只下够首帧），但不预下载更远的集。
          expect(createdUrls,
              ['https://cdn.example/1.mp4', 'https://cdn.example/2.mp4']);
          expect(manager.resolved, ['1', '2']);
          expect(manager.full, isEmpty);
          await emit(1, 'buffering', false);
          await settle();
        }

        if (scenario.lifecycle) {
          final observer =
              tester.state(find.byType(PlayerPage)) as WidgetsBindingObserver;
          List<String> currentCommands() =>
              callsOf(1).where((c) => c == 'play' || c == 'pause').toList();
          nativeCalls.clear();
          // 通知栏、弹窗和分屏失焦不能暂停或重启当前集。
          observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
          await tester.pump();
          observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await tester.pump();
          expect(currentCommands(), isEmpty);
          // 真正不可见（包括锁屏）暂停，paused 不重复暂停。
          observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
          await tester.pump();
          observer.didChangeAppLifecycleState(AppLifecycleState.paused);
          await tester.pump();
          expect(currentCommands(), ['pause']);
          observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
          await tester.pump();
          expect(currentCommands(), ['pause']);
          observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await tester.pump();
          expect(currentCommands(), ['pause', 'play']);
          // 已由音频冲突停止的播放器，前后台切换也不能擅自续播。
          await emit(1, 'playbackIntent', false);
          await emit(1, 'playing', false);
          nativeCalls.clear();
          observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
          observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await tester.pump();
          expect(currentCommands(), isEmpty);
          return;
        }

        // 当前集出首帧后立即预渲染下一集，不等当前集缓冲到一定时长。
        expect(createdUrls, [
          cached
              ? files[1]!.absolute.uri.toString()
              : 'https://cdn.example/1.mp4',
          cached
              ? files[2]!.absolute.uri.toString()
              : 'https://cdn.example/2.mp4',
        ]);
        expect(manager.resolved, cached ? isEmpty : ['1', '2']);
        expect(callsOf(2), containsAllInOrder(['prepareFirstFrame', 'pause']));
        expect(callsOf(2), isNot(contains('play')));
        expect(
            warmedUrls,
            cached
                ? isEmpty
                : [
                    if (start == 45000) 'https://cdn.example/1.mp4',
                    'https://cdn.example/2.mp4',
                  ]);
        // 预渲染之后沿方向预下载第 3 集的开头，不建播放器。
        expect(manager.full, scenario.count == 5 ? [2, 3] : [2]);
        expect(manager.bytes, everyElement(greaterThanOrEqualTo(1024 * 1024)));
        expect(createdUrls, hasLength(2));

        if (scenario.swipe) {
          nativeCalls.clear();
          await tester.drag(find.byType(PageView), const Offset(0, -500));
          await tester.pump(const Duration(seconds: 2));
          await settle();
          // 命中预渲染：第 2 集直接接管播放，不重新创建。
          expect(callsOf(2), contains('play'));
          // 第 1 集停声、停止下载后停放，不释放，往回滑时可以原位接着播。
          expect(callsOf(1),
              containsAllInOrder(['setVolume', 'pause', 'setActive']));
          expect(callsOf(1), isNot(contains('dispose')));
          // 接着沿方向预渲染第 3 集。
          expect(createdUrls.last, 'https://cdn.example/3.mp4');
          expect(manager.resolved, ['3']);
          // 往回滑：直接接管停放的第 1 集，不新建、不跳转进度，也不显示加载。
          nativeCalls.clear();
          await tester.drag(find.byType(PageView), const Offset(0, 500));
          await tester.pump(const Duration(seconds: 2));
          await settle();
          expect(createdUrls, hasLength(3));
          expect(callsOf(1), contains('play'));
          expect(callsOf(1), isNot(contains('seek')));
          expect(callsOf(1), isNot(contains('dispose')));
          // 预渲染的第 3 集不再相邻，释放；第 2 集改为停放，不重复预渲染。
          expect(callsOf(3), contains('dispose'));
          expect(callsOf(2), isNot(contains('dispose')));
          return;
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 400));
        debugDefaultTargetPlatformOverride = null;
      }
      expect(tester.takeException(), isNull);
    });
  }
}
