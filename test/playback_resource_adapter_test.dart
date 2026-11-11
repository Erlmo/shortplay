import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/theater_video_preload_manager.dart';

class _Api extends ApiClient {
  final replies = <Completer<List<FqVideoItem>>>[];
  @override
  Future<List<FqVideoItem>> fetchFqVideoModel(String videoId) {
    final reply = Completer<List<FqVideoItem>>();
    replies.add(reply);
    return reply.future;
  }
}

FqVideoItem item(String url, {String definition = '720p'}) => FqVideoItem(
    url: url,
    definition: definition,
    width: 720,
    height: 1280,
    bitrate: 1,
    spadeA: '',
    kid: '',
    codec: 'hevc',
    isEncrypted: false);

void main() {
  test('正式播放和预加载共享解析；换画质后旧返回不能污染新缓存', () async {
    final api = _Api();
    addTearDown(api.dispose);
    final configured = <String>[];
    final manager = TheaterVideoPreloadManager(
        apiClient: api,
        configureNetwork: (item) async => configured.add(item.url));
    final first = manager.resolvePlayUrl('video', episodeIndex: 0);
    final shared = manager.resolvePlayUrl('video', episodeIndex: 0);
    await Future<void>.delayed(Duration.zero);
    expect(api.replies, hasLength(1));
    manager.setPreferredDefinition('1080p');
    final changed = manager.resolvePlayUrl('video', episodeIndex: 0);
    await Future<void>.delayed(Duration.zero);
    expect(api.replies, hasLength(1));
    api.replies.single.complete([
      item('https://cdn.example/old.mp4'),
      item('https://cdn.example/new.mp4', definition: '1080p'),
    ]);
    expect(await changed, 'https://cdn.example/new.mp4');
    expect(await first, 'https://cdn.example/old.mp4');
    expect(await shared, 'https://cdn.example/old.mp4');
    expect(await manager.resolvePlayUrl('video', episodeIndex: 0),
        'https://cdn.example/new.mp4');
    expect(api.replies, hasLength(1));
    expect(configured, ['https://cdn.example/new.mp4']);
  });
  test('解密、参数等终止错误不盲目重复解析', () async {
    final api = _Api();
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(
        apiClient: api, configureNetwork: (_) async {});
    final pending = manager.resolvePlayUrl('video', episodeIndex: 0);
    final assertion = expectLater(pending, throwsA(isA<ApiException>()));
    await Future<void>.delayed(Duration.zero);
    api.replies.single.completeError(ApiException('解密参数无效', code: 502));
    await assertion;
    expect(api.replies, hasLength(1));
  });

  testWidgets('明确瞬时解析错误有限重试，成功后配置同一媒体候选', (tester) async {
    final api = _Api();
    addTearDown(api.dispose);
    final manager = TheaterVideoPreloadManager(
        apiClient: api, configureNetwork: (_) async {});
    final pending = manager.resolvePlayUrl('video', episodeIndex: 0);
    await tester.pump();
    api.replies.single
        .completeError(ApiException('temporary', code: 503, retryable: true));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(api.replies, hasLength(2));
    api.replies.last.complete([item('https://cdn.example/recovered.mp4')]);
    await tester.pump();
    expect(await pending, 'https://cdn.example/recovered.mp4');
  });
}
