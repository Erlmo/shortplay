import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

Map<String, Object> resolvedVideoStream({
  String definition = '720p',
  String codec = 'h264',
  String spade = 'server-spade',
  String url = 'https://cdn.example.com/video.mp4',
}) =>
    {
      'main_url': url,
      'definition': definition,
      'vwidth': 720,
      'vheight': 1280,
      'bitrate': 500000,
      'codec_type': codec,
      'spade_a': spade,
      'kid': 'server-kid',
      'decrypt_key': '0123456789abcdef0123456789abcdef',
      'expire_time': 4102444800,
      'cacheable': true,
    };

ResponseBody resolutionJson(Object? data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );

Map<String, Object?> resolutionResponse({List<Map<String, Object>>? streams}) =>
    {
      'code': 0,
      'data': {
        'protocol': 1,
        'action': 'complete',
        'result': {
          'video_id': '1234567890',
          'streams': streams ?? [resolvedVideoStream()],
          'poster_url': 'https://cdn.example.com/poster.jpg',
          'expire_time': 4102444800
        },
      },
    };

class VideoResolutionAdapter implements HttpClientAdapter {
  VideoResolutionAdapter({this.reply});
  final FutureOr<ResponseBody> Function(RequestOptions request)? reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    requests.add(options);
    if (reply != null) return await reply!(options);
    if (options.uri.path != '/algorithm/videorequest') {
      throw StateError('不应由客户端调用: ${options.uri.path}');
    }
    return resolutionJson(resolutionResponse());
  }

  @override
  void close({bool force = false}) {}
}
