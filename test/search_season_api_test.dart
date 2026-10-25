import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/search_source.dart';
import 'package:shortplay/services/api_client.dart';

import 'support/registered_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('系列集数协议保留真实vid和原始集数，忽略其他季及无效条目', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8765'));
    final api = ApiClient(dio: dio);
    addTearDown(() => dio.close(force: true));
    RequestOptions? request;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      request = options;
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'code': 0,
        'data': {
          'video_data': {
            'video_list': [
              {
                'vid': 'v-13-7',
                'series_id': '7690163276214176792',
                'vid_index': 7
              },
              {
                'vid': 'v-13-9',
                'series_id': '7690163276214176792',
                'vid_index': 9
              },
              {
                'vid': 'other',
                'series_id': '7621200213801176126',
                'vid_index': 1
              },
              {'vid': '', 'series_id': '7690163276214176792', 'vid_index': 10},
              {
                'vid': 'invalid',
                'series_id': '7690163276214176792',
                'vid_index': 0
              },
            ],
          },
        },
      }));
    }));
    final episodes = await api.fetchSearchSeason('7690163276214176792');
    expect(request!.path, '/nove/search/season');
    expect(request!.queryParameters, {
      'source': SearchSource.comic.value,
      'series_id': '7690163276214176792',
      'client_device': testRegisteredDeviceJson,
    });
    expect(episodes.map((episode) => episode.vid), ['v-13-7', 'v-13-9']);
    expect(episodes.map((episode) => episode.number), [7, 9]);
  });

  test('系列集数为空或响应格式无效时提示失败，取消原样传播', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8765'));
    final api = ApiClient(dio: dio);
    addTearDown(() => dio.close(force: true));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'code': 0,
        'data': {
          'video_data': {'video_list': []},
        },
      }));
    }));
    await expectLater(
        api.fetchSearchSeason('13'), throwsA(isA<ApiException>()));
    final token = CancelToken()..cancel('leave search');
    await expectLater(
        api.fetchSearchSeason('13', cancelToken: token),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)));
  });
}
