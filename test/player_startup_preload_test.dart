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
import 'package:shortplay/widgets/player/player_page_overlays.dart';

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
      PlaybackCancellation? cancellation}) async {
    full.add(targetIndex);
  }
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
          telemetry: false,
          lifecycle: false
        ),
    (cached: true, start: 0, swipe: true, telemetry: false, lifecycle: false),
    (cached: false, start: 0, swipe: false, telemetry: true, lifecycle: false),
    (cached: true, start: 0, swipe: false, telemetry: false, lifecycle: true),
  ]) {
    final cached = scenario.cached;
    final telemetry = scenario.telemetry;
    final start = scenario.start;
    testWidgets(
        '从${start}ms起播，缓存=$cached，立即上滑=${scenario.swipe}，真实缓冲=$telemetry，生命周期=${scenario.lifecycle}',
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
      Map<String, Object?>? nativeSnapshot;
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
        if (call.method == 'getBufferState') return nativeSnapshot;
        if (call.method == 'create') {
          createdUrls.add((call.arguments as Map)['cdnUrl'] as String);
          final id = ++nextId;
          await emit(id, 'duration', 120000);
          if (telemetry) await emit(id, 'bufferedAhead', 14000);
          if (id == 1) await emit(id, 'firstFrame', true);
          return {'playerId': id, 'textureId': id};
        }
        if (call.method == 'prepareFirstFrame') {
          await emit((call.arguments as Map)['id'] as int, 'firstFrame', true);
        }
        if (call.method == 'play' || call.method == 'pause') {
          final id = (call.arguments as Map)['id'] as int;
          await emit(id, 'playing', call.method == 'play');
        }
        return null;
      });
      addTearDown(() async {
        await NativePlayer.resetEventListenerForTesting();
        for (final c in [channel, events, crypto, SystemChannels.platform]) {
          messenger.setMockMethodCallHandler(c, null);
        }
      });
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
            '1',
            '2',
            '3'
          ], chapters: [
            for (var n = 1; n <= 3; n++)
              TheaterChapter(
                  itemId: '$n', title: '第$n集', realChapterOrder: '$n'),
          ])),
        )));
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        expect(createdUrls, [
          cached
              ? files[1]!.absolute.uri.toString()
              : "https://cdn.example/1.mp4",
          if (cached) files[2]!.absolute.uri.toString(),
        ]);
        expect(manager.resolved, cached ? isEmpty : ['1']);
        expect(
            warmedUrls,
            !cached && start == 45000
                ? ['https://cdn.example/1.mp4']
                : isEmpty);
        if (scenario.lifecycle) {
          final observer =
              tester.state(find.byType(PlayerPage)) as WidgetsBindingObserver;
          List<String> currentCommands() => nativeCalls
              .where((c) => (c.$2 as Map?)?['id'] == 1)
              .map((c) => c.$1)
              .where((c) => c == 'play' || c == 'pause')
              .toList();
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
        if (scenario.swipe) {
          expect(
              nativeCalls.where((c) =>
                  c.$1 == 'prepareFirstFrame' && (c.$2 as Map?)?['id'] == 2),
              hasLength(1));
          expect(
              nativeCalls
                  .where((c) => c.$1 == 'play' && (c.$2 as Map?)?['id'] == 2),
              isEmpty);
          final pages = tester.widget<PageView>(find.byType(PageView));
          expect(pages.physics, isNot(isA<BlockForwardScrollPhysics>()));
          await tester.drag(find.byType(PageView), const Offset(0, -500));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump();
          expect(find.byType(PlayerSwipeBlockedHint), findsNothing);
          expect(createdUrls, [
            files[1]!.absolute.uri.toString(),
            files[2]!.absolute.uri.toString(),
            'https://cdn.example/3.mp4',
          ]);
          // The cached current episode is fully buffered, so the SDK can
          // prepare the following network episode without starving playback.
          expect(manager.resolved, ['3']);
          // Completion arrives while the old engine is parked: returning to
          // it must rewind before play and reuse the same native instance.
          await emit(1, 'completed', true);
          nativeCalls.clear();
          await tester.drag(find.byType(PageView), const Offset(0, 500));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump();
          expect(createdUrls, hasLength(3));
          final oldEngineCalls =
              nativeCalls.where((c) => (c.$2 as Map?)?['id'] == 1).toList();
          final seek = oldEngineCalls.indexWhere((c) => c.$1 == 'seek');
          final play = oldEngineCalls.indexWhere((c) => c.$1 == 'play');
          expect(seek, greaterThanOrEqualTo(0));
          expect(play, greaterThan(seek));
          expect((oldEngineCalls[seek].$2 as Map)['positionMs'], 0);
          return;
        }
        await emit(1, 'position', start + 2999);
        await tester.pump();
        expect(manager.resolved, cached ? isEmpty : ['1']);
        await emit(1, 'buffering', true);
        await emit(1, 'position', start + 3000);
        await tester.pump();
        expect(manager.resolved, cached ? isEmpty : ['1']);
        await emit(1, 'buffering', false);
        await emit(1, 'position', start + 3100);
        await tester.pump();
        if (telemetry) {
          // 14 seconds exactly is not safe yet, even after 3s of playback.
          expect(manager.resolved, ['1']);
          // Position stays frozen: only the independent cache poll discovers
          // that the real native buffer became safe again.
          nativeSnapshot = {
            'bufferedAheadMs': 14001,
            'positionMs': start + 3100,
            'durationMs': 120000,
            'buffering': false,
            'playing': false,
            'completed': false,
          };
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
        }
        if (!cached && !telemetry) {
          expect(manager.resolved, ['1']);
          await emit(1, 'position', start + 6000);
          await tester.pump();
        }
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 20));
        expect(manager.resolved, cached ? isEmpty : ['1', '2']);
        expect(createdUrls, hasLength(2));
        expect(
            warmedUrls,
            cached
                ? isEmpty
                : [
                    if (start == 45000) 'https://cdn.example/1.mp4',
                    'https://cdn.example/2.mp4',
                  ]);
        expect(
            createdUrls.last,
            cached
                ? files[2]!.absolute.uri.toString()
                : 'https://cdn.example/2.mp4');
        expect(manager.full, isEmpty);
        await emit(1, 'position', start + 3500);
        await tester.pump();
        expect(manager.resolved, cached ? isEmpty : ['1', '2']);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        debugDefaultTargetPlatformOverride = null;
      }
      expect(tester.takeException(), isNull);
    });
  }
}
