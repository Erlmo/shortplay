import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/models/twixive.dart';
import 'package:shortplay/pages/twixive/twixive_list.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/liked_video_store.dart';

TwixiveVideo video(String id, {String? url}) => TwixiveVideo(
      id: id,
      url: url ?? 'https://video.example/$id.mp4',
      thumbnail: '',
      width: 1080,
      height: 1920,
      author: const TwixiveUser(
          id: 'author', username: 'example', name: '本地作者', avatar: ''),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() =>
      SharedPreferences.setMockInitialValues({'playback_history_v1': '[]'}));

  test('喜欢持久保存完整视频信息，按最近喜欢排序，取消按视频 ID 去重', () async {
    expect(await LikedVideoStore.load(), isEmpty);
    expect(await LikedVideoStore.toggle(video('1')), isTrue);
    await LikedVideoStore.toggle(video('2'));
    final saved = await LikedVideoStore.load();
    expect(saved.map((item) => item.id), ['2', '1']);
    expect(saved.first.author.name, '本地作者');
    expect(saved.first.width, 1080);
    expect(saved.first.height, 1920);
    expect(saved.first.url, 'https://video.example/2.mp4');
    expect(
        await LikedVideoStore.toggle(
            video('1', url: 'https://video.example/new-signed.mp4')),
        isFalse);
    expect((await LikedVideoStore.load()).map((item) => item.id), ['2']);
    expect(
        (await SharedPreferences.getInstance())
            .getString('playback_history_v1'),
        '[]');
  });

  test('并发喜欢不会丢数据，同一视频连续切换可回到未喜欢', () async {
    await Future.wait([
      LikedVideoStore.toggle(video('1')),
      LikedVideoStore.toggle(video('2'))
    ]);
    expect((await LikedVideoStore.load()).map((item) => item.id), ['2', '1']);
    await Future.wait([
      LikedVideoStore.toggle(video('3')),
      LikedVideoStore.toggle(video('3'))
    ]);
    expect(await LikedVideoStore.contains('3'), isFalse);
    expect((await LikedVideoStore.load()), hasLength(2));
  });

  testWidgets('喜欢列表只读取本地，点赞取消后同步刷新，不请求远端列表', (tester) async {
    await tester.runAsync(() => LikedVideoStore.toggle(video('1')));
    final api = ApiClient();
    var requests = 0;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      requests++;
      handler.reject(DioException(requestOptions: request));
    }));
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TwixiveList(apiClient: api, likedOnly: true))));
    await tester.runAsync(() async {
      await LikedVideoStore.load();
    });
    await tester.pumpAndSettle();
    expect(find.text('本地作者'), findsOneWidget);
    await tester.runAsync(() => LikedVideoStore.toggle(video('1')));
    await tester.pumpAndSettle();
    expect(find.text('本地作者'), findsNothing);
    expect(find.textContaining('还没有喜欢的视频'), findsOneWidget);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
