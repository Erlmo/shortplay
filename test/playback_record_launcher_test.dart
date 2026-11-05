import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/episode.dart';
import 'package:shortplay/models/playback_record.dart';
import 'package:shortplay/pages/playback_record_launcher.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/download_service.dart';
import 'package:shortplay/services/native_player.dart';

import 'support/video_resolution_adapter.dart';

class _Downloads extends DownloadService {
  _Downloads(ApiClient api, Directory directory, this.fixtureGroups)
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
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const playerChannel = MethodChannel('shortplay/native_player');
  const eventsChannel = MethodChannel('shortplay/native_player/events');

  for (final cachedNumber in [1, 3]) {
    testWidgets('历史续播第3集，缓存第$cachedNumber集时选择正确的播放来源', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('history-source-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final local = File('${directory.path}/ep_$cachedNumber.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      final adapter = VideoResolutionAdapter(reply: (request) {
        if (request.uri.path == '/nove/directory') {
          return resolutionJson({
            'code': 0,
            'data': {
              'lists': [
                for (var n = 1; n <= 3; n++)
                  {'item_id': '123456789$n', 'title': '第$n集'}
              ],
            },
          });
        }
        if (request.uri.path == '/nove/seasons') {
          return resolutionJson({'code': 0, 'data': <String, dynamic>{}});
        }
        return resolutionJson(resolutionResponse(streams: [
          resolvedVideoStream(
              url: 'https://cdn.example.com/fresh-episode3.mp4'),
        ]));
      });
      final api = ApiClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(api.dispose);
      final download = EpisodeDownload(
        dramaId: '1234567890',
        dramaName: '测试剧',
        episode:
            Episode(index: cachedNumber, name: '缓存集', size: 0, url: 'old-id'),
        status: DownloadStatus.completed,
        localPath: local.path,
      );
      final service = _Downloads(api, directory, {
        '1234567890': DramaDownloadGroup(
          dramaId: '1234567890',
          dramaName: '测试剧',
          episodes: [download],
        ),
      });
      await tester.runAsync(service.ensureLoaded);
      addTearDown(service.dispose);
      final created = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(eventsChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
          SystemChannels.platform, (_) async => null);
      messenger.setMockMethodCallHandler(playerChannel, (call) async {
        if (call.method == 'create') {
          created.add(Map<dynamic, dynamic>.from(call.arguments as Map));
          // 到原生边界为止，验证传入的地址与密钥；测试环境不创建真实解码器。
          throw PlatformException(code: 'test-player-boundary');
        }
        return null;
      });
      addTearDown(() async {
        await NativePlayer.resetEventListenerForTesting();
        messenger.setMockMethodCallHandler(playerChannel, null);
        messenger.setMockMethodCallHandler(eventsChannel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      const record = PlaybackRecord(
        dramaId: 1234567890,
        dramaName: '测试剧',
        cover: '',
        episodeIndex: 2,
        episodeNumber: 3,
        positionMs: 15000,
        updatedAtMs: 1,
      );
      await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                  onPressed: () => unawaited(openPlaybackRecord(context,
                      record: record,
                      apiClient: api,
                      downloadService: service)),
                  child: const Text('续播'),
                )),
      ));
      try {
        await tester.tap(find.text('续播'));
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 400));
        for (var i = 0; i < 10 && created.isEmpty; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
        expect(player.initialEpisodeNumber, 3);
        expect(player.initialPositionMs, 15000);
        expect(created, hasLength(1));
        if (cachedNumber == 3) {
          expect(player.offlineEpisodes, isNotNull);
          expect(created.single['cdnUrl'], local.absolute.uri.toString());
          expect(created.single['keyHex'], '');
          expect(
              adapter.requests.where((r) => r.uri.path == '/algorithm/video'),
              isEmpty);
        } else {
          expect(player.offlineEpisodes, isNull);
          final requests =
              adapter.requests.where((r) => r.uri.path == '/algorithm/video');
          expect(requests, hasLength(1));
          expect(requests.single.data, {'video_id': '1234567893'});
          expect(created.single['cdnUrl'],
              'https://cdn.example.com/fresh-episode3.mp4');
          expect(created.single['keyHex'], '0123456789abcdef0123456789abcdef');
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
