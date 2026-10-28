import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';

class _ResolvedApi extends ApiClient {
  _ResolvedApi({this.nearlyExpired = false, this.cacheable = true});
  final bool nearlyExpired;
  final bool cacheable;
  var resolves = 0;
  @override
  Future<List<FqVideoItem>> fetchFqVideoModel(String id) async {
    resolves++;
    return [
      FqVideoItem(
          url: 'https://cdn.example/v$resolves.mp4',
          definition: '720p',
          width: 720,
          height: 1280,
          bitrate: 1000,
          spadeA: 'synthetic',
          kid: 'kid',
          codec: 'h264',
          decryptKey: '0123456789abcdef0123456789abcdef',
          cacheable: cacheable,
          expiresAt: DateTime.now().add(nearlyExpired && resolves == 1
              ? const Duration(seconds: 10)
              : const Duration(hours: 1)))
    ];
  }

  @override
  Future<String> fetchDecryptKey(String spade) =>
      throw StateError('已有key，不应请求服务器解密');
}

void main() {
  test('有效的统一解析信息复用地址与key', () async {
    final api = _ResolvedApi();
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(apiClient: api);
    final first = await manager.resolvePlayUrl('1234567890', episodeIndex: 0);
    expect(await manager.resolvePlayUrl('1234567890', episodeIndex: 0), first);
    expect(api.resolves, 1);
  });
  test('临近上游有效期时丢弃预加载地址，重新解析', () async {
    final api = _ResolvedApi(nearlyExpired: true);
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(apiClient: api);
    final first = await manager.resolvePlayUrl('1234567890', episodeIndex: 0);
    final next = await manager.resolvePlayUrl('1234567890', episodeIndex: 0);
    expect(next, isNot(first));
    expect(api.resolves, 2);
    expect(await manager.availableDefinitions('1234567890'), ['720p']);
    expect(api.resolves, 2);
  });
  test('服务端没有明确有效期时不固定缓存地址', () async {
    final api = _ResolvedApi(cacheable: false);
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(apiClient: api);
    final first = await manager.resolvePlayUrl('1234567890', episodeIndex: 0);
    expect(await manager.resolvePlayUrl('1234567890', episodeIndex: 0),
        isNot(first));
    expect(api.resolves, 2);
  });
}
