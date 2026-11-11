import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';
import 'package:shortplay_playback_sdk/shortplay_playback_sdk.dart';

const renditions = [
  QualityRendition('360p', 100000, 'low'),
  QualityRendition('720p', 400000, 'middle'),
  QualityRendition('1080p', 800000, 'high'),
];

class _Api extends ApiClient {
  var count = 0;
  @override
  Future<List<FqVideoItem>> fetchFqVideoModel(String id) async {
    count++;
    return [
      for (final q in renditions)
        FqVideoItem(
            url: 'https://cdn.example/$id-${q.value}.mp4',
            definition: q.definition,
            width: 0,
            height: 0,
            bitrate: q.bitrate,
            codec: 'hevc',
            spadeA: '',
            kid: '',
            isEncrypted: false)
    ];
  }
}

void main() {
  test('默认档回退按原enum序而非像素，距离相同保持原列表首项', () {
    expect(
        PlaybackQualitySelector.defaultResolution(
                [renditions.first, renditions.last], '720p')
            .value,
        'high');
    final tie = [
      const QualityRendition('480p', 200000, '480'),
      renditions.last
    ];
    expect(PlaybackQualitySelector.defaultResolution(tie, '720p').value, '480');
    expect(
        PlaybackQualitySelector.defaultResolution(tie.reversed.toList(), '720p')
            .value,
        'high');
    expect(
        PlaybackQualitySelector.defaultResolution([
          const QualityRendition('540p', 300000, '540'),
          renditions.last
        ], '720p')
            .value,
        'high');
  });
  test('明确目标码率选floor；目标未知或低于所有档位保持默认', () {
    final fallback = renditions[1];
    for (final target in [
      null,
      0.0,
      -1.0,
      double.nan,
      double.infinity,
      50000.0
    ]) {
      expect(
          PlaybackQualitySelector.byTargetBitrate(renditions, target, fallback),
          same(fallback));
    }
    expect(
        PlaybackQualitySelector.byTargetBitrate(renditions, 500000, fallback)
            .value,
        'middle');
    expect(
        PlaybackQualitySelector.byTargetBitrate(renditions, 900000, fallback)
            .value,
        'high');
    final ties = [
      renditions[1],
      const QualityRendition('720p', 400000, 'other')
    ];
    expect(
        PlaybackQualitySelector.byTargetBitrate(ties, 500000, fallback).value,
        'middle');
  });
  test('SpeedShift预算不足选最低，等码率floor取后项，与画像分支不同', () {
    expect(
        PlaybackQualitySelector.maxUnderBudget(renditions, 50000).value, 'low');
    expect(PlaybackQualitySelector.maxUnderBudget(renditions, 500000).value,
        'middle');
    expect(
        PlaybackQualitySelector.maxUnderBudget([
          renditions[1],
          const QualityRendition('720p', 400000, 'other')
        ], 500000)
            .value,
        'other');
  });
  test('SpeedShift只用显式系数或带宽表，不补猜测的默认系数', () {
    const config = PolynomialBitrateConfig(1, 2, 3, 4, 100);
    expect(config.target(2), 100);
    expect(config.target(5), 194);
    expect(config.target(0), isNull);
    expect(config.target(double.infinity), isNull);
    final bands = [
      const BandwidthBitrateBand(10, 100),
      const BandwidthBitrateBand(20, 200)
    ];
    expect(configuredBandwidthTarget(10, bands), 100);
    expect(configuredBandwidthTarget(11, bands), 200);
    expect(configuredBandwidthTarget(30, bands), 200);
    expect(configuredBandwidthTarget(10, []), isNull);
  });
  test('连点换档保留首次进度与暂停意图，只最新票据可完成', () {
    final controller = QualitySwitchCoordinator();
    final first = controller.begin('1080p',
        position: const Duration(seconds: 45), wantsPlaying: false)!;
    expect(
        controller.begin('1080p', position: Duration.zero, wantsPlaying: true),
        isNull);
    final second =
        controller.begin('360p', position: Duration.zero, wantsPlaying: true)!;
    expect(first.cancellation.isCancelled, true);
    expect(second.position, const Duration(seconds: 45));
    expect(second.wantsPlaying, false);
    controller.finish(first);
    expect(controller.isCurrent(second), true);
    controller.cancel();
    expect(controller.isCurrent(second), false);
  });
  test('宿主无预测器保持默认档，模型在换画质时复用且不混源', () async {
    final api = _Api();
    addTearDown(api.dispose);
    final configured = <FqVideoItem>[];
    final manager = TheaterVideoPreloadManager(
        apiClient: api, configureNetwork: (item) async => configured.add(item));
    expect(manager.adaptiveQualityAvailable, false);
    expect(await manager.resolvePlayUrl('video', episodeIndex: 0),
        endsWith('middle.mp4'));
    manager.setPreferredDefinition('1080p');
    expect(await manager.resolvePlayUrl('video', episodeIndex: 0),
        endsWith('high.mp4'));
    expect(api.count, 1);
    expect(configured.map((e) => e.definition), ['720p', '1080p']);
  });
  test('有真实目标输入才能自适应选档，手动锁定不被新目标覆盖', () async {
    final api = _Api();
    addTearDown(api.dispose);
    var target = 900000.0;
    final manager = TheaterVideoPreloadManager(
        apiClient: api,
        configureNetwork: (_) async {},
        targetBitrateProvider: () => target);
    expect(manager.adaptiveQualityAvailable, true);
    expect(await manager.resolvePlayUrl('one', episodeIndex: 0),
        endsWith('high.mp4'));
    manager.setPreferredDefinition('720p');
    target = 2000000;
    expect(manager.adaptiveQualityAvailable, false);
    expect(await manager.resolvePlayUrl('two', episodeIndex: 1),
        endsWith('middle.mp4'));
    manager.useAutomaticQuality();
    target = 150000;
    expect(await manager.resolvePlayUrl('three', episodeIndex: 2),
        endsWith('low.mp4'));
  });
}
