import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/playback_policy_service.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

Map<String, dynamic> sample() => jsonDecode(
        File('test/fixtures/playback_policy_73970.json').readAsStringSync())
    as Map<String, dynamic>;

const levels = ['360p', '480p', '540p', '720p', '1080p'];

class _Video extends ApiClient {
  @override
  Future<List<FqVideoItem>> fetchFqVideoModel(String id) async => [
        for (final name in levels)
          FqVideoItem(
              url: 'https://cdn.example/$id-$name.mp4',
              definition: name,
              width: 0,
              height: 0,
              bitrate: 100000,
              spadeA: '',
              kid: '',
              codec: 'hevc',
              isEncrypted: false)
      ];
}

String? select(PlaybackPolicyService policy,
        {int index = 1, bool preload = false}) =>
    policy.evaluate(
        renditions: [
          for (final name in levels)
            RemoteDramaRendition(name.toUpperCase(), 100000)
        ],
        allowedDefinitions: levels.map((v) => v.toUpperCase()).toList(),
        episodeIndex: index,
        isPreload: preload)?.definition;

void main() {
  test('实际新接口回包经正式解析选择540P，缓存和手选仍优先', () async {
    final policy = PlaybackPolicyService(fetch: () async => sample());
    addTearDown(policy.dispose);
    await policy.refresh();
    expect(select(policy), '540P');
    expect(policy.nextRefresh, const Duration(seconds: 300));
    final api = _Video();
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(
        apiClient: api,
        playbackPolicies: policy,
        hasCachedMedia: (_) => false,
        configureNetwork: (_) async {});
    expect(await manager.resolvePlayUrl('fresh', episodeIndex: 0),
        endsWith('540p.mp4'));
    manager.setPreferredDefinition('1080p');
    expect(await manager.resolvePlayUrl('manual', episodeIndex: 0),
        endsWith('1080p.mp4'));
    final cached = TheaterVideoPreloadManager(
        apiClient: api,
        playbackPolicies: policy,
        hasCachedMedia: (item) => item.definition == '720p',
        configureNetwork: (_) async {});
    expect(await cached.resolvePlayUrl('cached', episodeIndex: 0),
        endsWith('720p.mp4'));
  });

  test('限集使用真实1基序号，前两集不降档，第3集才应用', () async {
    final payload = sample();
    (payload['data'] as Map)['strategies']['peak_demotion'] =
        '{"resolution":"540P","resolution_in_peak_min_episode_index":2}';
    final policy = PlaybackPolicyService(fetch: () async => payload)
      ..accept(payload);
    addTearDown(policy.dispose);
    final api = _Video();
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(
        apiClient: api,
        playbackPolicies: policy,
        configureNetwork: (_) async {});
    expect(await manager.resolvePlayUrl('first', episodeIndex: 0),
        endsWith('720p.mp4'));
    expect(await manager.resolvePlayUrl('second', episodeIndex: 1),
        endsWith('720p.mp4'));
    expect(await manager.resolvePlayUrl('third', episodeIndex: 2),
        endsWith('540p.mp4'));
  });

  test('后台策略请求未返回也可立即起播，刷新不重选已经准备的源', () async {
    final pending = Completer<Map<String, dynamic>?>();
    final policy = PlaybackPolicyService(fetch: () => pending.future)..start();
    addTearDown(policy.dispose);
    final api = _Video();
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(
        apiClient: api,
        playbackPolicies: policy,
        configureNetwork: (_) async {});
    expect(await manager.resolvePlayUrl('prepared', episodeIndex: 0),
        endsWith('720p.mp4'));
    pending.complete(sample());
    await Future<void>.delayed(Duration.zero);
    expect(select(policy), '540P');
    expect(await manager.resolvePlayUrl('prepared', episodeIndex: 0),
        endsWith('720p.mp4'));
    expect(
        await manager.resolvePlayUrl('next', episodeIndex: 1, forPreload: true),
        endsWith('540p.mp4'));
  });

  test('原始字符串JSON解析，3次失败清动态策略但保留keepAlive历史', () {
    var now = DateTime(2026, 11, 9, 12);
    final payload = sample();
    (payload['data'] as Map)['is_peak_period'] = false;
    (payload['data'] as Map)['strategies']['resolution_strategy'] = jsonEncode({
      'resolution_strategy_list': [
        {
          'suggest_resolution_type': '1080p',
          'keep_alive_duration': 30,
          'ignore_peak': true
        }
      ]
    });
    final policy =
        PlaybackPolicyService(fetch: () async => null, clock: () => now)
          ..accept(payload);
    addTearDown(policy.dispose);
    expect(select(policy), '1080P');
    for (var i = 1; i <= 3; i++) {
      policy.recordFailure();
      expect(policy.nextRefresh, Duration(seconds: i * 10));
    }
    expect(select(policy), isNull);
    final next = sample();
    (next['data'] as Map)['is_peak_period'] = false;
    (next['data'] as Map)['strategies']['resolution_strategy'] =
        '{"resolution_strategy_list":[]}';
    now = now.add(const Duration(seconds: 1));
    policy.accept(next);
    expect(select(policy), '1080P');
    now = now.add(const Duration(seconds: 30));
    expect(select(policy), isNull);
  });

  test('Settings模型按原Lazy锁存，动态peak回包仍可更新', () {
    final policy = PlaybackPolicyService(fetch: () async => null)
      ..accept(sample());
    addTearDown(policy.dispose);
    final next = sample();
    (next['settings'] as Map)['server_series_resolution_v655']
        ['enable_server'] = false;
    (next['data'] as Map)['strategies']['peak_demotion'] =
        '{"resolution":"480P"}';
    policy.accept(next);
    expect(select(policy), '480P');
    (next['data'] as Map)['is_peak_period'] = false;
    policy.accept(next);
    expect(select(policy), isNull);
  });

  test('真实测量缺失不伪造网速，坏字符串JSON不阻塞选档', () {
    final payload = sample();
    (payload['settings'] as Map)['resolution_net_strategy_v649']
        ['enable_net_resolution'] = true;
    final policy = PlaybackPolicyService(fetch: () async => null)
      ..accept(payload);
    addTearDown(policy.dispose);
    final result = policy.evaluate(
        renditions: const [RemoteDramaRendition('720P', 300000)],
        allowedDefinitions: const ['720P'],
        episodeIndex: 1,
        isPreload: false)!;
    expect(result.isResolved, false);
    expect(result.missingInputs, contains('portraitTargetMegabitsPerSecond'));
    expect(result.definition, isNull);
    final corrupt = sample();
    (corrupt['data'] as Map)['strategies']['peak_demotion'] = 'not-json';
    (corrupt['data'] as Map)['strategies']['resolution_strategy'] = '{}';
    final other = PlaybackPolicyService(fetch: () async => null)
      ..accept(corrupt);
    addTearDown(other.dispose);
    expect(() => select(other), returnsNormally);
  });

  test('旧服务端无接口会停止自动请求，非法数据不锁存配置', () async {
    var calls = 0;
    final policy = PlaybackPolicyService(fetch: () async {
      calls++;
      return null;
    });
    addTearDown(policy.dispose);
    policy.start();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(policy.hasSettings, false);
    final bad = sample();
    bad['data'] = ['invalid'];
    expect(() => policy.accept(bad), throwsFormatException);
    expect(policy.hasSettings, false);
  });
}
