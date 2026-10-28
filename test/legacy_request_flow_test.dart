import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shortplay/config/api_config.dart';
import 'package:shortplay/models/search_results.dart';
import 'package:shortplay/services/api_client.dart';

import 'support/video_resolution_adapter.dart';

const _oldDeviceCacheKey = 'home_registered_device_v1';

class _LegacyRequestAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  List<RequestOptions> at(String path) =>
      requests.where((request) => request.uri.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final Map<String, Object> response;
    switch (options.uri.path) {
      case ApiConfig.algorithmVideoRequest:
        response = resolutionResponse().cast<String, Object>();
      case ApiConfig.noveHome:
        response = {
          'code': 0,
          'data': {
            'list': <Object>[],
            'offset': 20,
            'session_id': 'legacy-session',
            'has_more': false,
          },
        };
      case ApiConfig.noveSearchSuggest:
        response = {
          'code': 0,
          'data': {'query': '万妖', 'items': <Object>[]},
        };
      case ApiConfig.noveSearch:
        response = {'code': 0, 'search_tabs': <Object>[]};
      case ApiConfig.noveDirectory:
        response = {
          'code': 0,
          'data': {'lists': <Object>[]},
        };
      case ApiConfig.notice:
        response = {'code': 0, 'data': <Object>[]};
      case ApiConfig.appUpdate:
        response = {
          'code': 0,
          'data': {'update_available': false},
        };
      default:
        throw StateError('不应发出的请求: ${options.uri.path}');
    }
    return ResponseBody.fromString(jsonEncode(response), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

(ApiClient, _LegacyRequestAdapter) _client() {
  final adapter = _LegacyRequestAdapter();
  final client = ApiClient(
    dio: Dio(BaseOptions(baseUrl: 'https://legacy.test:8443'))
      ..httpClientAdapter = adapter,
  );
  addTearDown(client.dispose);
  return (client, adapter);
}

void main() {
  test('业务请求不附加安装身份，播放公共参数不读取遗留缓存', () async {
    const oldCache = '旧设备缓存故意保留为无效JSON';
    SharedPreferences.setMockInitialValues({_oldDeviceCacheKey: oldCache});
    final prefs = await SharedPreferences.getInstance();
    final (client, adapter) = _client();

    await client.fetchHomePage(offset: 20, sessionId: 'legacy-session');
    await client.fetchSearchSuggestions('万妖');
    await client.searchResults(const SearchQuery(query: '万妖'));
    await client.fetchTheaterEpisodes('1234567890');
    await client.fetchNotice();
    await client.checkAppUpdate(device: 'ios', version: '3.2.0+19');
    final video = (await client.fetchFqVideoModel('2234567890')).single;
    final key = await client.fetchDecryptKey(video.spadeA);

    expect(key, '0123456789abcdef0123456789abcdef');
    expect(adapter.requests, hasLength(7));
    for (final request in adapter.requests) {
      expect(request.queryParameters, isNot(contains('client_device')));
      expect(request.uri.queryParameters, isNot(contains('client_device')));
      expect(request.uri.path,
          isNot(anyOf('/device/register', '/nove/playback/report')));
      expect(request.uri.origin, 'https://legacy.test:8443');
    }
    expect(adapter.at(ApiConfig.noveHome).single.queryParameters, {
      'offset': '20',
      'session_id': 'legacy-session',
    });
    expect(adapter.at(ApiConfig.appUpdate).single.queryParameters, {
      'device': 'ios',
      'version': '3.2.0+19',
    });
    expect(adapter.at(ApiConfig.algorithmVideoRequest).single.data,
        {'video_id': '2234567890'});
    expect(prefs.getString(_oldDeviceCacheKey), oldCache);
    expect(prefs.getKeys(), {_oldDeviceCacheKey});
  });

  test('播放只传视频ID，设备与签名完全留在服务端，不保存安装身份', () async {
    SharedPreferences.setMockInitialValues({});
    final (client, adapter) = _client();
    await client.fetchFqVideoModel('1234567890');
    await client.fetchFqVideoModel('1234567890');
    final requests = adapter.at(ApiConfig.algorithmVideoRequest);
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request.data, {'video_id': '1234567890'});
      expect(request.queryParameters, isEmpty);
      expect(request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('x-ss-dp')));
    }
    expect(adapter.requests, hasLength(2));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });
}
