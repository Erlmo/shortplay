import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/api_config.dart';
import 'api_client.dart';

class TvLinkSession {
  const TvLinkSession(
      {required this.id,
      required this.readToken,
      required this.inputUrl,
      required this.expiresAt});

  final String id;
  final String readToken;
  final String inputUrl;
  final DateTime expiresAt;

  factory TvLinkSession.fromJson(Map<String, dynamic> json) {
    final id = json['session_id']?.toString() ?? '';
    final token = json['read_token']?.toString() ?? '';
    final url = json['input_url']?.toString() ?? '';
    final uri = Uri.tryParse(url);
    final expires = int.tryParse(json['expires_at']?.toString() ?? '');
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token) ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host != Uri.parse(ApiConfig.noveBaseUrl).host ||
        expires == null) {
      throw ApiException('二维码数据无效，请刷新后重试');
    }
    return TvLinkSession(
        id: id,
        readToken: token,
        inputUrl: url,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expires * 1000));
  }

  Map<String, String> get credentials =>
      {'session_id': id, 'read_token': readToken};
}

class TvLinkStatus {
  const TvLinkStatus({required this.state, this.text});
  final String state;
  final String? text;
}

/// 复用 APP 的验签连接。扫码网页只能投递，无法使用电视端的读取凭证。
class TvLinkApi {
  TvLinkApi(this.apiClient);
  final ApiClient apiClient;

  Future<Map<String, dynamic>> _post(String action, Map<String, dynamic> data,
      {CancelToken? cancelToken}) async {
    try {
      final response = await apiClient.dio
          .post('/tvlink/$action', data: data, cancelToken: cancelToken);
      final body = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (body is! Map || body['code'] != 0) {
        throw ApiException(
            body is Map ? body['message']?.toString() ?? '扫码服务异常' : '扫码服务返回无效');
      }
      final result = body['data'];
      if (result is! Map) throw ApiException('扫码服务返回无效');
      return result.cast<String, dynamic>();
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      final body = error.response?.data;
      throw ApiException(
          body is Map
              ? body['message']?.toString() ?? '扫码服务暂时不可用'
              : '无法连接扫码服务，请确认服务端已更新',
          code: error.response?.statusCode);
    } on FormatException {
      throw ApiException('扫码服务返回无效，请确认服务端已更新');
    }
  }

  Future<TvLinkSession> create({CancelToken? cancelToken}) async =>
      TvLinkSession.fromJson(
          await _post('create', {}, cancelToken: cancelToken));

  Future<TvLinkStatus> status(TvLinkSession session,
      {CancelToken? cancelToken}) async {
    final data =
        await _post('status', session.credentials, cancelToken: cancelToken);
    final state = data['state']?.toString() ?? '';
    final text = data['text']?.toString();
    if (!['pending', 'submitted', 'consumed'].contains(state) ||
        (state == 'submitted' && (text == null || text.trim().isEmpty))) {
      throw ApiException('扫码状态无效，请刷新二维码');
    }
    return TvLinkStatus(state: state, text: text);
  }

  Future<void> acknowledge(TvLinkSession session,
      {CancelToken? cancelToken}) async {
    await _post('acknowledge', session.credentials, cancelToken: cancelToken);
  }

  Future<void> cancel(TvLinkSession session) async {
    await _post('cancel', session.credentials);
  }
}
