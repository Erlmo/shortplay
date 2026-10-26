import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shortplay/config/api_config.dart';
import 'package:shortplay/models/search_results.dart';
import 'package:shortplay/services/api_client.dart';

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
      case ApiConfig.algorithmSign:
        response = {
          'code': 0,
          'data': {
            'x-test-signature': 'sign-${at(ApiConfig.algorithmSign).length}'
          },
        };
      case ApiConfig.algorithmSpade:
        response = {
          'code': 0,
          'data': {'key': '0123456789abcdef0123456789abcdef'},
        };
      case ApiConfig.fqVideoPath:
        response = {
          'code': 0,
          'data': {
            'video_model': jsonEncode({
              'video_list': [
                {
                  'main_url': 'https://cdn.example.com/video.mp4',
                  'video_meta': {
                    'definition': '720p',
                    'codec_type': 'h264',
                    'vwidth': 720,
                    'vheight': 1280,
                    'bitrate': 500000,
                  },
                  'encrypt_info': {'spade_a': 'video-spade', 'kid': 'kid'},
                },
              ],
            }),
          },
        };
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
  test('业务和播放请求不注册或附加安装身份，遗留设备缓存不会影响请求', () async {
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
    expect(adapter.requests, hasLength(9));
    for (final request in adapter.requests) {
      expect(request.queryParameters, isNot(contains('client_device')));
      expect(request.uri.queryParameters, isNot(contains('client_device')));
      expect(request.uri.path,
          isNot(anyOf('/device/register', '/nove/playback/report')));
      if (request.uri.path != ApiConfig.fqVideoPath) {
        expect(request.uri.origin, 'https://legacy.test:8443');
      }
    }
    expect(adapter.at(ApiConfig.noveHome).single.queryParameters, {
      'offset': '20',
      'session_id': 'legacy-session',
    });
    expect(adapter.at(ApiConfig.appUpdate).single.queryParameters, {
      'device': 'ios',
      'version': '3.2.0+19',
    });
    expect(adapter.at(ApiConfig.algorithmSign).single.queryParameters, isEmpty);
    expect(
        adapter.at(ApiConfig.algorithmSpade).single.queryParameters, isEmpty);
    expect(prefs.getString(_oldDeviceCacheKey), oldCache);
    expect(prefs.getKeys(), {_oldDeviceCacheKey});
  });

  test('每次视频解析生成临时参数，签名与实际视频请求保持一致', () async {
    SharedPreferences.setMockInitialValues({});
    final (client, adapter) = _client();

    await client.fetchFqVideoModel('same-video');
    await client.fetchFqVideoModel('same-video');

    final videos = adapter.at(ApiConfig.fqVideoPath);
    final signs = adapter.at(ApiConfig.algorithmSign);
    expect(videos, hasLength(2));
    expect(signs, hasLength(2));
    for (final entry in videos.indexed) {
      final video = entry.$2;
      final query = video.uri.queryParameters;
      expect(query['iid'], matches(RegExp(r'^[1-9][0-9]{18}$')));
      expect(query['device_id'], matches(RegExp(r'^[1-9][0-9]{15}$')));
      expect(query['device_brand'], 'Xiaomi');
      expect(query['os_version'], '13');
      expect((signs[entry.$1].data as Map)['url'], video.uri.toString());
      expect(video.headers['user-agent'], ApiConfig.fqUserAgent);
      expect(video.headers['Host'], video.uri.host);
      expect(video.headers['x-test-signature'], 'sign-${entry.$1 + 1}');
      expect(video.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')));
    }
    final first = videos.first.uri.queryParameters;
    final second = videos.last.uri.queryParameters;
    expect(second['iid'], isNot(first['iid']));
    expect(second['device_id'], isNot(first['device_id']));
    expect(second['cdid'], first['cdid']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });
}
