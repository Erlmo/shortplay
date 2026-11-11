import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/drama.dart';
import 'package:shortplay/models/drama_season.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/native_player.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';
import 'package:shortplay/widgets/player/player_controls_overlay.dart';

import 'support/video_resolution_adapter.dart';

class _Qualities extends TheaterVideoPreloadManager {
  _Qualities(ApiClient api)
      : super(apiClient: api, configureNetwork: (_) async {});
  @override
  String selectedDefinition(String id) => preferredDefinition;
  @override
  Future<List<String>> availableDefinitions(String id) async =>
      ['360p', '720p', '1080p'];
  @override
  Future<String> resolvePlayUrl(String id,
          {required int episodeIndex,
          int maxRetries = 3,
          bool forPreload = false}) async =>
      'https://cdn.example/$preferredDefinition.mp4';
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

  for (final scenario in ['playing', 'paused', 'rapid']) {
    testWidgets('真实播放页换画质 $scenario 保留45000ms且只按最终意图播放', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = ApiClient(
          dio: Dio()
            ..httpClientAdapter = VideoResolutionAdapter(
                reply: (_) =>
                    resolutionJson({'code': 0, 'data': <String, dynamic>{}})));
      final manager = _Qualities(api);
      var next = 0;
      final calls = <(String, Map)>[];
      final rapid = scenario == 'rapid';
      messenger.setMockMethodCallHandler(
          SystemChannels.platform, (_) async => null);
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments is Map
            ? call.arguments as Map
            : <Object?, Object?>{};
        calls.add((call.method, Map.of(args)));
        if (call.method == 'create') {
          final id = ++next;
          await emit(id, 'duration', 120000);
          await emit(id, 'position', args['initialPositionMs'] ?? 45000);
          if (id == 1) await emit(id, 'firstFrame', true);
          return {'playerId': id, 'textureId': id};
        }
        if (call.method == 'prepareFirstFrame' && !rapid) {
          await emit(args['id'] as int, 'firstFrame', true);
        }
        if (call.method == 'play' || call.method == 'pause') {
          await emit(args['id'] as int, 'playing', call.method == 'play');
        }
        return null;
      });
      addTearDown(() async {
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
                    name: '画质测试',
                    actors: '',
                    cover: '',
                    intro: '',
                    tags: const [],
                    status: '',
                    updateTime: ''),
                apiClient: api,
                preloadManager: manager,
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
        PlayerControlsOverlay overlay() => tester.widget<PlayerControlsOverlay>(
            find.byType(PlayerControlsOverlay).first);
        if (scenario == 'paused') {
          overlay().onTogglePlay();
          await tester.pump();
        }
        final change = overlay().onQualityChanged!;
        calls.clear();
        change('1080p');
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        if (rapid) {
          change('360p');
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          // Pause while switching: a late old frame must not publish/play.
          overlay().onTogglePlay();
          await tester.pump();
          await emit(2, 'firstFrame', true);
          await emit(3, 'firstFrame', true);
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
        }
        final creates = calls.where((c) => c.$1 == 'create').toList();
        expect(creates.length, rapid ? 2 : 1);
        for (final create in creates) {
          expect(create.$2['initialPositionMs'], 45000);
        }
        final target = rapid ? 3 : 2;
        final plays =
            calls.where((c) => c.$1 == 'play' && c.$2['id'] == target).toList();
        expect(plays.length, scenario == 'playing' ? 1 : 0);
        expect(calls.where((c) => c.$1 == 'seek' && c.$2['id'] == target),
            isEmpty);
        expect(overlay().positionMsNotifier.value, 45000);
        expect(overlay().playerInitialized, true);
        if (rapid) {
          expect(
              calls.where((c) => c.$1 == 'play' && c.$2['id'] == 2), isEmpty);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    });
  }
}
