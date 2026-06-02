import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/api_config.dart';
import 'sign_native.dart';

/// Dio interceptor that automatically signs requests to api.weeou.com
/// with the X-Dusa header (medusa_lite algorithm, native .so).
///
/// Only signs requests whose host matches [ApiConfig.noveBaseUrl].
/// Requests to other hosts (e.g. fqnovel.com) pass through unsigned.
class SignInterceptor extends Interceptor {
  final _targetHost = Uri.parse(ApiConfig.noveBaseUrl).host;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!SignNative.isSupported) {
      handler.next(options);
      return;
    }

    final uri = options.uri;
    if (uri.host != _targetHost) {
      handler.next(options);
      return;
    }

    final method = options.method.toUpperCase();
    final path = uri.path.isEmpty ? '/' : uri.path;

    // Query: sort by key, encode same as PHP http_build_query(ksort())
    final sorted = Map.fromEntries(
      uri.queryParameters.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    );
    final query = sorted.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    // Body: for POST with JSON, serialize to string for signing
    String body = '';
    if (options.data != null) {
      if (options.data is Map || options.data is List) {
        body = jsonEncode(options.data);
      } else if (options.data is String) {
        body = options.data as String;
      }
    }

    final sign = SignNative.instance.sign(
      method: method,
      path: path,
      query: query,
      body: body,
    );

    if (sign != null) {
      options.headers['X-Dusa'] = sign;
    }

    handler.next(options);
  }
}
