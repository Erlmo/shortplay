import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/playback_preferences.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';

class _QualityApi extends ApiClient {
  _QualityApi({this.definitions = const ['360p', '720p', '1080p']});
  final List<String> definitions;
  var requests = 0;

  @override
  Future<List<FqVideoItem>> fetchFqVideoModel(String id) async {
    requests++;
    return [
      for (final definition in definitions)
        FqVideoItem(
          url: 'https://cdn.example/$id-$definition.mp4',
          definition: definition,
          width: 0,
          height: 0,
          bitrate: 100000,
          codec: 'hevc',
          spadeA: '',
          kid: '',
          isEncrypted: false,
        )
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PlaybackPreferences.load();
  });
  tearDown(() async {
    SharedPreferences.setMockInitialValues({});
    await PlaybackPreferences.load();
  });

  test('默认清晰度持久保存，重新加载后恢复选择', () async {
    expect(PlaybackPreferences.defaultDefinition.value, 'auto');
    await PlaybackPreferences.save('1080p');
    PlaybackPreferences.defaultDefinition.value = 'auto';
    await PlaybackPreferences.load();
    expect(PlaybackPreferences.defaultDefinition.value, '1080p');
    expect(() => PlaybackPreferences.save('bad'), throwsArgumentError);
  });

  test('不同视频和新播放器都优先使用全局清晰度，不被旧缓存档位覆盖', () async {
    await PlaybackPreferences.save('1080p');
    final api = _QualityApi();
    addTearDown(api.dispose);
    TheaterVideoPreloadManager manager() => TheaterVideoPreloadManager(
          apiClient: api,
          configureNetwork: (_) async {},
          hasCachedMedia: (item) => item.definition == '360p',
          targetBitrateProvider: () => 1,
        );
    final first = manager();
    expect(await first.resolvePlayUrl('one', episodeIndex: 0),
        endsWith('1080p.mp4'));
    expect(await first.resolvePlayUrl('two', episodeIndex: 1),
        endsWith('1080p.mp4'));
    expect(await manager().resolvePlayUrl('three', episodeIndex: 0),
        endsWith('1080p.mp4'));
    expect(first.adaptiveQualityAvailable, isFalse);
  });

  test('缺少所选档位时使用可用画质', () async {
    await PlaybackPreferences.save('1080p');
    final api = _QualityApi(definitions: ['360p', '720p']);
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(
        apiClient: api, configureNetwork: (_) async {});
    expect(await manager.resolvePlayUrl('one', episodeIndex: 0),
        endsWith('720p.mp4'));
  });

  test('设置更改会更新已解析的画质，播放页临时切换不修改全局默认', () async {
    await PlaybackPreferences.save('720p');
    final api = _QualityApi();
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(
        apiClient: api, configureNetwork: (_) async {});
    expect(await manager.resolvePlayUrl('one', episodeIndex: 0),
        endsWith('720p.mp4'));
    await PlaybackPreferences.save('1080p');
    expect(await manager.resolvePlayUrl('one', episodeIndex: 0),
        endsWith('1080p.mp4'));
    expect(api.requests, 1);
    manager.setPreferredDefinition('360p');
    expect(await manager.resolvePlayUrl('one', episodeIndex: 0),
        endsWith('360p.mp4'));
    expect(PlaybackPreferences.defaultDefinition.value, '1080p');
  });
}
