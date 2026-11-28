import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/drama_season.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/services/native_player.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';

import 'support/video_resolution_adapter.dart';

class _Urls extends TheaterVideoPreloadManager {
  _Urls(ApiClient api) : super(apiClient: api, configureNetwork: (_) async {});
  @override
  Future<String> resolvePlayUrl(String id,
          {required int episodeIndex,
          int maxRetries = 3,
          bool forPreload = false}) async =>
      'https://cdn.example/$id.mp4';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shortplay/native_player');
  const events = MethodChannel('shortplay/native_player/events');
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

  for (final device in ['macOS', 'tv']) {
    testWidgets('$device 单击画面：Mac 暂停，电视只切换控制栏', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final wasTv = DeviceProfile.isTv;
      if (device == 'macOS') {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      } else {
        DeviceProfile.isTv = true;
      }
      final api = ApiClient(
          dio: Dio()
            ..httpClientAdapter = VideoResolutionAdapter(
                reply: (_) =>
                    resolutionJson({'code': 0, 'data': <String, dynamic>{}})));
      final calls = <String>[];
      var next = 0;
      messenger.setMockMethodCallHandler(
          SystemChannels.platform, (_) async => null);
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments is Map
            ? call.arguments as Map
            : <Object?, Object?>{};
        calls.add(call.method);
        if (call.method == 'create') {
          final id = ++next;
          await emit(id, 'duration', 120000);
          await emit(id, 'position', 0);
          await emit(id, 'firstFrame', true);
          return {'playerId': id, 'textureId': id};
        }
        if (call.method == 'play' || call.method == 'pause') {
          await emit(args['id'] as int, 'playing', call.method == 'play');
        }
        return null;
      });
      addTearDown(() async {
        debugDefaultTargetPlatformOverride = null;
        DeviceProfile.isTv = wasTv;
        await NativePlayer.resetEventListenerForTesting();
        for (final c in [channel, events, SystemChannels.platform]) {
          messenger.setMockMethodCallHandler(c, null);
        }
        api.dispose();
      });
      try {
        await tester.pumpWidget(MaterialApp(
            home: PlayerPage(
                drama: Drama(
                    id: 1234567890,
                    name: '点击测试',
                    actors: '',
                    cover: '',
                    intro: '',
                    tags: const [],
                    status: '',
                    updateTime: ''),
                apiClient: api,
                preloadManager: _Urls(api),
                seasons: const DramaSeasons(
                    albumId: '', currentSeason: 1, seasons: []),
                prefetchedEpisodes: Future.value(TheaterEpisodesResult(
                    allItemIds: [
                      '1234567890'
                    ],
                    chapters: [
                      TheaterChapter(
                          itemId: '1234567890',
                          title: '第一集',
                          realChapterOrder: '1')
                    ])))));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(calls, contains('play'));
        calls.clear();

        await tester.tapAt(tester.getCenter(find.byType(PlayerPage)));
        await tester.pump(const Duration(milliseconds: 50));

        if (device == 'macOS') {
          expect(calls, contains('pause'));
        } else {
          expect(calls, isNot(contains('pause')));
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
