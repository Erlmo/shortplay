import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay_playback_sdk/src/remote_drama_policy.dart';

const _allowed = ['360P', '480P', '540P', '720P', '1080P'];
const _profiles = [
  RemoteDramaRendition('360P', 200000),
  RemoteDramaRendition('480P', 400000),
  RemoteDramaRendition('540P', 600000),
  RemoteDramaRendition('720P', 1000000),
  RemoteDramaRendition('1080P', 2000000),
];
const _noPeak = RemoteDramaLocalPeak(
    resolutionType: 0, resolutionTypeForLow: 0, resolutionTypeForMidLow: 0);
const _local480 = RemoteDramaLocalPeak(
    resolutionType: 2, resolutionTypeForLow: 0, resolutionTypeForMidLow: 0);

RemoteDramaNetStrategy _net({
  bool enabled = false,
  bool preloadBest = false,
  int type = 2,
  bool smallest = false,
}) =>
    RemoteDramaNetStrategy(
      enableNetResolution: enabled,
      lowerTimePreloadBestQuality: preloadBest,
      netSpeedType: type,
      notMatchUseSmallest: smallest,
    );

RemoteDramaStrategy _strategy(String? resolution,
        {bool ignore = false,
        int keepAlive = 0,
        RemoteDramaLimitCondition? condition}) =>
    RemoteDramaStrategy(
        resolution: resolution,
        ignorePeak: ignore,
        keepAliveDuration: keepAlive,
        limitCondition: condition);

RemoteDramaPolicyInput _input({
  bool hasModel = true,
  bool enableServer = true,
  bool enable713 = false,
  bool digg = false,
  bool enablePeakServer = false,
  bool videoarch = false,
  RemoteDramaNetStrategy? network,
  RemoteDramaLocalPeak local = _noPeak,
  List<RemoteDramaStrategy>? strategies = const [],
  List<RemoteDramaRendition?>? profiles = _profiles,
  List<String> allowed = _allowed,
  bool preload = false,
  int index = 1,
  int now = 10000,
  RemoteDramaServerPeak? server,
  bool? peak = false,
  bool? low = false,
  bool? midLow = false,
  bool? connected = true,
  bool? wifi = true,
  double? predictor = 2000000,
  double? portrait = 2,
  String? function,
}) =>
    RemoteDramaPolicyInput(
      hasVideoModel: hasModel,
      enableServerStrategy: enableServer,
      enableV713Strategy: enable713,
      diggStrategy: digg,
      enableServerPeak: enablePeakServer,
      useVideoarchPeakPeriod: videoarch,
      networkStrategy: network ?? _net(),
      localPeak: local,
      strategies: strategies,
      renditions: profiles,
      allowedDefinitions: allowed,
      isPreload: preload,
      episodeIndex: index,
      nowMilliseconds: now,
      serverPeak: server,
      isPeakTime: peak,
      isLowDevice: low,
      isMiddleLowDevice: midLow,
      networkAvailable: connected,
      wifiEnabled: wifi,
      nativePredictorBitsPerSecond: predictor,
      portraitTargetMegabitsPerSecond: portrait,
      bitrateFunction: function,
    );

void main() {
  test('原h只接受大写P，预制策略会大写而服务器降档不会', () {
    for (final name in _allowed) {
      expect(parseRemoteDramaResolution(name), name);
    }
    for (final name in [null, '', '720p', 'SuperHigh', '4K']) {
      expect(parseRemoteDramaResolution(name), isNull);
    }
    final policy = RemoteDramaPolicy();
    expect(policy.evaluate(_input(strategies: [_strategy('1080p')])).definition,
        '1080P');
    expect(
        policy
            .evaluate(_input(
                enablePeakServer: true,
                server: const RemoteDramaServerPeak(
                    resolution: '540p', limitIndex: -1, enabled: true)))
            .definition,
        isNull);
  });

  test('空模型不读取配置或更新策略；两个预制开关为或关系', () {
    final item = _strategy('1080P');
    final policy = RemoteDramaPolicy();
    expect(
        policy.evaluate(_input(hasModel: false, strategies: [item])).definition,
        isNull);
    expect(policy.lastStrategy, isNull);
    expect(
        policy
            .evaluate(_input(enableServer: false, strategies: [item]))
            .definition,
        isNull);
    expect(
        policy
            .evaluate(_input(
                enableServer: false, enable713: true, strategies: [item]))
            .definition,
        '1080P');
  });

  test('keepAlive保留原项且不续期，列表null不使用旧策略，边界相等过期', () {
    final original = _strategy('1080p', keepAlive: 5);
    final replacement = _strategy('540P');
    final policy = RemoteDramaPolicy();
    expect(
        policy.evaluate(_input(now: 1000, strategies: [original])).definition,
        '1080P');
    expect(policy.lastStrategy, same(original));
    expect(
        policy
            .evaluate(_input(now: 5999, strategies: [replacement]))
            .definition,
        '1080P');
    expect(policy.lastStrategyTimeMilliseconds, 1000);
    expect(policy.evaluate(_input(now: 5999, strategies: null)).definition,
        isNull);
    expect(
        policy
            .evaluate(_input(now: 6000, strategies: [replacement]))
            .definition,
        '540P');
    expect(policy.lastStrategy, same(replacement));
    expect(policy.lastStrategyTimeMilliseconds, 6000);
  });

  test('keepAlive复用时不重新检查网络条件；32位TTL溢出与时钟回退保留原语义', () {
    const wifiOnly =
        RemoteDramaLimitCondition(isWifi: true, checkNetSpeed: false);
    final original = _strategy('1080P', keepAlive: 5, condition: wifiOnly);
    final policy = RemoteDramaPolicy();
    expect(
        policy.evaluate(_input(now: 1000, strategies: [original])).definition,
        '1080P');
    expect(
        policy
            .evaluate(_input(
                now: 500,
                strategies: [original],
                wifi: false,
                connected: false))
            .definition,
        '1080P');
    final overflow = _strategy('1080P', keepAlive: 2147484);
    policy.restoreKeepAlive(overflow, 1000);
    expect(
        policy
            .evaluate(_input(now: 1001, strategies: [_strategy('480P')]))
            .definition,
        '480P');
  });

  test('无limitCondition不会添加digg拦截器；无效解析项跳过', () {
    final policy = RemoteDramaPolicy();
    expect(
        policy
            .evaluate(_input(
                digg: true,
                strategies: [_strategy('unknown'), _strategy('1080P')]))
            .definition,
        '1080P');
    expect(
        policy
            .evaluate(_input(digg: true, strategies: [
              _strategy('1080P',
                  condition: const RemoteDramaLimitCondition(
                      isWifi: false, checkNetSpeed: false))
            ]))
            .definition,
        isNull);
  });

  test('WiFi拒绝断网或非WiFi，未测得条件明确返回缺失而不假定联网', () {
    final strategies = [
      _strategy('1080P',
          condition: const RemoteDramaLimitCondition(
              isWifi: true, checkNetSpeed: false)),
      _strategy('720P'),
    ];
    for (final states in [(false, true), (true, false)]) {
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  strategies: strategies,
                  connected: states.$1,
                  wifi: states.$2))
              .definition,
          '720P');
    }
    final unknown = RemoteDramaPolicy()
        .evaluate(_input(strategies: strategies, connected: null, wifi: true));
    expect(unknown.definition, isNull);
    expect(unknown.missingInputs, contains('networkAvailable'));
  });

  test('网络阈值以KB每秒比较，type1大于等于通过，type2严格小于通过', () {
    for (final type in [1, 2, 0]) {
      final strategies = [
        _strategy('1080P',
            condition: RemoteDramaLimitCondition(
                isWifi: false,
                checkNetSpeed: false,
                netSpeed: RemoteDramaSpeedCondition(
                    networkSpeed: 500, checkNetType: type))),
        _strategy('720P'),
      ];
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(strategies: strategies, predictor: 4000000))
              .definition,
          type == 1 ? '1080P' : '720P');
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(strategies: strategies, predictor: 3999999))
              .definition,
          type == 2 ? '1080P' : '720P');
    }
  });

  test('质量测速拦截按原五档rank，未知4K不被当成高于1080P', () {
    final strategies = [
      _strategy('1080P',
          condition: const RemoteDramaLimitCondition(
              isWifi: false, checkNetSpeed: true)),
      _strategy('720P'),
    ];
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(strategies: strategies, predictor: 1000000))
            .definition,
        '720P');
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(strategies: strategies, predictor: 2000000))
            .definition,
        '1080P');
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(
                strategies: strategies,
                profiles: [
                  ..._profiles,
                  const RemoteDramaRendition('4K', 3000000)
                ],
                predictor: 4000000))
            .definition,
        '720P');
  });

  test('服务器降档存在时禁用和索引限制不回退本地高峰，-1绕过限制', () {
    final strategies = [_strategy('1080P')];
    for (final server in [
      const RemoteDramaServerPeak(
          resolution: '540P', limitIndex: -1, enabled: false),
      const RemoteDramaServerPeak(
          resolution: '540P', limitIndex: 3, enabled: true),
    ]) {
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  strategies: strategies,
                  enablePeakServer: true,
                  server: server,
                  index: 3,
                  local: _local480,
                  peak: true))
              .definition,
          '1080P');
    }
    const server =
        RemoteDramaServerPeak(resolution: '540P', limitIndex: 3, enabled: true);
    for (final index in [4, -1]) {
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  strategies: strategies,
                  enablePeakServer: true,
                  server: server,
                  index: index,
                  peak: false))
              .definition,
          '540P');
    }
  });

  test('本地高峰覆盖低档设备优先，受允许列表限制，非高峰无降档', () {
    const local = RemoteDramaLocalPeak(
        resolutionType: 0, resolutionTypeForLow: 1, resolutionTypeForMidLow: 2);
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(local: local, peak: true, low: true, midLow: true))
            .definition,
        '540P');
    expect(
        RemoteDramaPolicy()
            .evaluate(
                _input(local: local, peak: true, low: false, midLow: true))
            .definition,
        '480P');
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(local: local, peak: false, low: true))
            .definition,
        isNull);
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(local: _local480, peak: true, allowed: ['720P']))
            .definition,
        isNull);
  });

  test('非网络模式中ignorePeak控制服务器或本地降档能否覆盖预制结果', () {
    for (final ignore in [false, true]) {
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  strategies: [_strategy('1080P', ignore: ignore)],
                  local: _local480,
                  peak: true))
              .definition,
          ignore ? '1080P' : '480P');
    }
  });

  test('网络模式及videoarch开关覆盖预制结果，但已选策略保存副作用仍发生', () {
    for (final videoarch in [false, true]) {
      final policy = RemoteDramaPolicy();
      final item = _strategy('1080P', ignore: true);
      expect(
          policy
              .evaluate(_input(
                  strategies: [item],
                  videoarch: videoarch,
                  network: _net(enabled: !videoarch),
                  predictor: 1000000))
              .definition,
          '720P');
      expect(policy.lastStrategy, same(item));
      expect(policy.lastStrategyTimeMilliseconds, 10000);
    }
  });

  test('网络floor同码率取首项；正目标无匹配时才允许最低档兜底', () {
    final profiles = [
      const RemoteDramaRendition('360P', 200000),
      const RemoteDramaRendition('540P', 1000000),
      const RemoteDramaRendition('720P', 1000000),
    ];
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(
                profiles: profiles,
                network: _net(enabled: true),
                predictor: 1000000))
            .definition,
        '540P');
    for (final smallest in [false, true]) {
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  network: _net(enabled: true, smallest: smallest),
                  predictor: 100000))
              .definition,
          smallest ? '360P' : null);
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  network: _net(enabled: true, smallest: smallest),
                  predictor: 0))
              .definition,
          isNull);
    }
  });

  test('网络type1只用画像Mbps，type2只用native预测，不互相伪造输入', () {
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(
                network: _net(enabled: true, type: 1),
                predictor: 10000000,
                portrait: 0.8))
            .definition,
        '540P');
    final missing = RemoteDramaPolicy().evaluate(_input(
        network: _net(enabled: true, type: 1),
        predictor: 10000000,
        portrait: null));
    expect(missing.definition, isNull);
    expect(missing.missingInputs, {'portraitTargetMegabitsPerSecond'});
  });

  test('ShortPlay三次函数使用Mbps且不夹minimum，坏CSV保留原目标', () {
    for (final entry in {
      '0,0,0.25,0': '480P',
      'bad,0,0,1': '1080P',
      '0,0,0,-1': null,
      '0,0,0': '1080P',
    }.entries) {
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  network: _net(enabled: true, smallest: true),
                  predictor: 2000000,
                  function: entry.key))
              .definition,
          entry.value);
    }
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(
                network: _net(enabled: true, smallest: true),
                predictor: 0,
                function: '0,0,0,10'))
            .definition,
        isNull);
  });

  test('高峰网络组合取允许顺序较低档，两项均非null才校验交集', () {
    const server = RemoteDramaServerPeak(
        resolution: '540P', limitIndex: -1, enabled: true);
    for (final allowed in [
      _allowed,
      ['720P', '1080P'],
      ['720P']
    ]) {
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  network: _net(enabled: true),
                  peak: true,
                  enablePeakServer: true,
                  server: server,
                  allowed: allowed))
              .definition,
          allowed.contains('540P')
              ? '540P'
              : (allowed.contains('1080P') ? '1080P' : null));
    }
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(
                network: _net(enabled: true), peak: true, allowed: ['720P']))
            .definition,
        '1080P');
  });

  test('非高峰预加载可取至少720，普通播放与关闭开关不会强升', () {
    for (final preload in [false, true]) {
      expect(
          RemoteDramaPolicy()
              .evaluate(_input(
                  network: _net(enabled: true, preloadBest: true),
                  preload: preload,
                  predictor: 200000))
              .definition,
          preload ? '720P' : '360P');
    }
    expect(
        RemoteDramaPolicy()
            .evaluate(_input(
                network: _net(enabled: true, preloadBest: true),
                preload: true,
                predictor: 200000,
                allowed: ['360P']))
            .definition,
        '360P');
  });

  test('未知预测和未知高峰状态均不猜测，保留明确missingInputs', () {
    final noPredictor = RemoteDramaPolicy()
        .evaluate(_input(network: _net(enabled: true), predictor: null));
    expect(noPredictor.definition, isNull);
    expect(noPredictor.isResolved, isFalse);
    expect(noPredictor.missingInputs, {'nativePredictorBitsPerSecond'});
    final noPeak = RemoteDramaPolicy()
        .evaluate(_input(network: _net(enabled: true), peak: null));
    expect(noPeak.definition, isNull);
    expect(noPeak.missingInputs, {'isPeakTime'});
  });

  test('本地分钟范围含端点、支持跨午夜，相同起止不是全天', () {
    bool inside(int sh, int sm, int eh, int em, int h, int m) =>
        remoteDramaMinuteInRange(
            startHour: sh,
            startMinute: sm,
            endHour: eh,
            endMinute: em,
            currentHour: h,
            currentMinute: m);
    expect(inside(18, 0, 20, 0, 18, 0), isTrue);
    expect(inside(18, 0, 20, 0, 20, 0), isTrue);
    expect(inside(18, 0, 20, 0, 20, 1), isFalse);
    expect(inside(22, 0, 1, 0, 0, 30), isTrue);
    expect(inside(22, 0, 1, 0, 12, 0), isFalse);
    expect(inside(12, 0, 12, 0, 12, 0), isTrue);
    expect(inside(12, 0, 12, 0, 12, 1), isFalse);
  });
}
