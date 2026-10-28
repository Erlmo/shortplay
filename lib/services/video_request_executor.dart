import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 只执行后端下发的HTTP描述，不包含上游业务参数、签名或解析规则。
class VideoRequestExecutor {
  VideoRequestExecutor({Dio? dio}) : _dio = dio ?? Dio();
  final Dio _dio;
  static const maxResponseBytes = 524288;

  Future<Map<String, dynamic>> execute(
    Map<String, dynamic> envelope, {
    required CancelToken cancelToken,
  }) async {
    final id = envelope['request_id'];
    final raw = envelope['request'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        raw is! Map) {
      throw const FormatException('播放请求描述无效');
    }
    final url = raw['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    final method = raw['method'];
    final body = raw['body'];
    final rawHeaders = raw['headers'];
    final timeout = raw['timeout_ms'];
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasFragment ||
        uri.host == 'localhost' ||
        uri.host.endsWith('.local') ||
        InternetAddress.tryParse(uri.host)?.isLoopback == true ||
        url!.length > 16384 ||
        !['GET', 'POST'].contains(method) ||
        body is! String ||
        utf8.encode(body).length > 65536 ||
        rawHeaders is! Map ||
        timeout is! int ||
        timeout < 1) {
      throw const FormatException('播放请求配置无效');
    }
    final headers = <String, String>{};
    for (final entry in rawHeaders.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
              .hasMatch(entry.key as String) ||
          (entry.value as String).contains(RegExp(r'[\r\n]'))) {
        throw const FormatException('播放请求头无效');
      }
      headers[entry.key as String] = entry.value as String;
    }
    // 独立Dio，不继承自有API的X-Dusa、Cookie或其他拦截器。
    final duration = Duration(milliseconds: timeout.clamp(1, 8000));
    _dio.options.connectTimeout = duration;
    final result = <String, dynamic>{
      'request_id': id,
      'status_code': 0,
      'body_base64': ''
    };
    try {
      final response = await _dio.request<ResponseBody>(
        url,
        data: body,
        cancelToken: cancelToken,
        options: Options(
            method: method as String,
            headers: headers,
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (_) => true,
            receiveTimeout: duration,
            sendTimeout: duration),
      );
      final bytes = BytesBuilder(copy: false);
      final stream = response.data;
      if (stream != null) {
        await for (final chunk in stream.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            return result..['error'] = 'response_too_large';
          }
          bytes.add(chunk);
        }
      }
      return result
        ..['status_code'] = response.statusCode ?? 0
        ..['body_base64'] = base64Encode(bytes.takeBytes());
    } on DioException catch (error) {
      if (cancelToken.isCancelled) rethrow;
      return result
        ..['error'] = [
          DioExceptionType.connectionTimeout,
          DioExceptionType.receiveTimeout,
          DioExceptionType.sendTimeout
        ].contains(error.type)
            ? 'timeout'
            : 'connection';
    } on IOException {
      return result..['error'] = 'connection';
    }
  }

  void dispose() => _dio.close(force: true);
}
