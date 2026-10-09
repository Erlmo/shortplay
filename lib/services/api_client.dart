import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../config/api_config.dart';
import '../models/danmaku.dart';
import '../models/drama.dart';
import '../models/episode.dart';
import '../models/fq_video.dart';
import 'sign_interceptor.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => 'ApiException(message: $message, code: $code)';
}

class ApiClient {
  ApiClient({Dio? dio, String? baseUrl})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? ApiConfig.noveBaseUrl,
                connectTimeout: ApiConfig.connectTimeout,
                receiveTimeout: ApiConfig.receiveTimeout,
                sendTimeout: ApiConfig.sendTimeout,
              ),
            ) {
    _dio.interceptors.add(SignInterceptor());
  }

  final Dio _dio;
  final Map<String, Drama> _dramaCache = {};

  /// 暴露已配置 SignInterceptor 的 Dio，供 ShareLinkResolver 等复用同一签名链路。
  Dio get dio => _dio;

  Future<Drama> fetchDramaDetail(String dramaId) async {
    if (_dramaCache.containsKey(dramaId)) return _dramaCache[dramaId]!;
    final candidates = <({String path, Map<String, dynamic> query})>[
      (path: '/api/detail', query: {'id': dramaId}),
      (path: '/api/detail', query: {'series_id': dramaId}),
      (path: '/api/drama_detail', query: {'id': dramaId}),
      (path: '/api/drama', query: {'id': dramaId}),
    ];

    Object? lastError;
    for (final candidate in candidates) {
      try {
        final response = await _dio.get(
          candidate.path,
          queryParameters: candidate.query,
        );
        final payload = _decode(response);
        final data = payload['data'];
        Drama? drama;
        if (data is Map<String, dynamic>) drama = Drama.fromJson(data);
        if (data is Map) drama = Drama.fromJson(data.cast<String, dynamic>());
        final nested = payload['drama'];
        if (nested is Map<String, dynamic>) drama = Drama.fromJson(nested);
        if (nested is Map)
          drama = Drama.fromJson(nested.cast<String, dynamic>());
        if (drama != null) {
          _dramaCache[dramaId] = drama;
          return drama;
        }
        throw ApiException('解析接口返回失败');
      } catch (error) {
        lastError = error;
      }
    }

    if (lastError is ApiException) throw lastError;
    throw ApiException('请求失败');
  }

  Future<({List<Drama> dramas, bool hasMore})> search(
    String keyword, {
    int offset = 0,
  }) async {
    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveSearch,
      {
        'key': keyword,
        'tab_type': '11',
        if (offset > 0) 'offset': offset.toString(),
      },
    );
    final response = await _dio.getUri(uri);
    final decoded = _decode(response);
    final searchTabs = decoded['search_tabs'] as List? ?? [];
    final dramaTab = searchTabs.firstWhere(
      (tab) => tab is Map && (tab['tab_type'] == 19 || tab['tab_type'] == 11),
      orElse: () => null,
    );
    if (dramaTab == null) return (dramas: <Drama>[], hasMore: false);
    final hasMore = (dramaTab as Map)['has_more'] == true;
    final data = dramaTab['data'] as List? ?? [];
    final dramas = <Drama>[];
    for (final item in data) {
      if (item is! Map) continue;
      final videoData = (item['video_data'] as List?)?.firstOrNull;
      if (videoData is! Map) continue;
      dramas.add(
        Drama.fromTheaterSearchJson(videoData.cast<String, dynamic>()),
      );
    }
    return (dramas: dramas, hasMore: hasMore);
  }

  /// 请求番茄官方API获取加密视频信息
  Future<List<FqVideoItem>> fetchFqVideoModel(String videoId) async {
    final requestTimer = Stopwatch()..start();
    // iid / device_id 每次随机生成（番茄风控按设备维度限流，固定值易被封）。
    // 同一组值同时用于签名请求与番茄请求，保证服务端签名的 URL 与实际请求逐字一致。
    // 以下 9 个参数为实测的最小必需集：缺签名服务强制项(iid/device_id/aid/
    // version_code/version_name/device_brand/os_version/cdid)会签名失败；
    // 缺 device_platform 番茄返回空；update_version_code 缺失时服务端不下发
    // 1080p 档位。
    final iid = _randomNumericId(19);
    final deviceId = _randomNumericId(16);
    final queryString = 'iid=$iid'
        '&device_id=$deviceId'
        '&aid=${ApiConfig.fqAid}'
        '&version_code=72132'
        '&version_name=7.2.1.32'
        '&update_version_code=72132'
        '&device_brand=Xiaomi'
        '&os_version=13'
        '&device_platform=android'
        '&cdid=75e2081b-d8bf-4767-91e8-3424546b4d2e';
    final fullUrl =
        'https://${ApiConfig.fqVideoHost}${ApiConfig.fqVideoPath}?$queryString';

    final candidates = await _requestFqVideoModel(videoId, fullUrl);
    final items = candidates.where((item) => !_isByteVc2(item)).toList();
    if (items.length == candidates.length) return items;

    // 新版参数可能把低清晰度换成 ByteVC2，当前原生播放器不能解码。
    // 保留兼容的 1080p，再用旧参数补回低清晰度，供播放、菜单及下载共用。
    final uri = Uri.parse(fullUrl);
    final legacyQuery = Map<String, String>.of(uri.queryParameters)
      ..remove('update_version_code');
    final legacyUrl = uri.replace(queryParameters: legacyQuery).toString();
    // 调用方的总超时为 10 秒；可选补充最多等 3 秒，并给总预算留出余量。
    final remainingMs = 9000 - requestTimer.elapsedMilliseconds;
    if (items.isNotEmpty && remainingMs <= 0) return items;
    final legacyTimeout = Duration(milliseconds: remainingMs.clamp(1, 3000));
    final legacyCancel = CancelToken();
    try {
      final legacyItems = await _requestFqVideoModel(
        videoId,
        legacyUrl,
        cancelToken: legacyCancel,
      ).timeout(legacyTimeout, onTimeout: () {
        legacyCancel.cancel('兼容视频补充请求超时');
        throw TimeoutException('兼容视频补充请求超时', legacyTimeout);
      });
      final definitions =
          items.map((item) => item.definition.trim().toLowerCase()).toSet();
      for (final item in legacyItems) {
        if (!_isByteVc2(item) &&
            definitions.add(item.definition.trim().toLowerCase())) {
          items.add(item);
        }
      }
    } catch (_) {
      // 补充请求失败时仍可使用首次请求已获得的兼容流。
      if (items.isEmpty) rethrow;
    }
    if (items.isEmpty) {
      throw ApiException('当前视频暂无播放器支持的编码');
    }
    return items;
  }

  static bool _isByteVc2(FqVideoItem item) {
    final codec = item.codec.trim().toLowerCase();
    return codec == 'bytevc2' || codec == 'bvc2';
  }

  Future<List<FqVideoItem>> _requestFqVideoModel(
    String videoId,
    String fullUrl, {
    CancelToken? cancelToken,
  }) async {
    // 1. 获取算法签名
    final signResponse = await _dio.post(
      '${ApiConfig.noveBaseUrl}${ApiConfig.algorithmSign}',
      data: {'url': fullUrl},
      cancelToken: cancelToken,
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final signDecoded = _asJsonMap(signResponse.data);
    if (signDecoded['code'] != 0) {
      throw ApiException('算法签名失败');
    }
    final signData = signDecoded['data'] as Map<String, dynamic>? ?? {};

    // 2. 请求番茄视频API
    final fqHeaders = <String, String>{
      'Host': ApiConfig.fqVideoHost,
      'user-agent': ApiConfig.fqUserAgent,
      'content-type': 'application/json; charset=utf-8',
      'accept': 'application/json; charset=utf-8,application/x-protobuf',
      'x-ss-dp': ApiConfig.fqAid,
      'sdk-version': '2',
    };
    for (final key in signData.keys) {
      fqHeaders[key] = signData[key].toString();
    }

    final body = {
      'video_id': videoId,
      'content_type': 1004,
      'biz_param': {
        'detail_page_version': 0,
        'device_level': 3,
        'disable_digg_stat': false,
        'disable_video_relate_book': false,
        'from_video_id': '',
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'source': 4,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 3,
      },
    };

    final fqResponse = await _dio.post(
      fullUrl,
      data: body,
      cancelToken: cancelToken,
      options: Options(headers: fqHeaders),
    );
    final fqDecoded = _asJsonMap(fqResponse.data);
    if (fqDecoded['code'] != 0) {
      throw ApiException('获取视频信息失败: ${fqDecoded['message'] ?? ''}');
    }

    final data = fqDecoded['data'] as Map<String, dynamic>? ?? {};
    final videoModelStr = data['video_model']?.toString() ?? '{}';
    final videoModel = jsonDecode(videoModelStr) as Map<String, dynamic>;
    final videoListRaw = videoModel['video_list'];
    final posterUrl = videoModel['poster_url']?.toString() ?? '';

    // video_list can be array or object depending on API version
    List<Map<String, dynamic>> videoEntries;
    if (videoListRaw is List) {
      videoEntries = videoListRaw
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } else if (videoListRaw is Map) {
      videoEntries = videoListRaw.values
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } else {
      videoEntries = [];
    }

    final items = videoEntries
        .map((item) => FqVideoItem.fromJson(item))
        .where((v) => v.url.isNotEmpty && v.spadeA.isNotEmpty)
        .toList();

    for (final item in items) {
      item.posterUrl = posterUrl;
    }
    return items;
  }

  /// 生成 [length] 位随机数字字符串，首位非 0（用于 iid / device_id）。
  static final Random _idRandom = Random();
  String _randomNumericId(int length) {
    final buffer = StringBuffer()..write(1 + _idRandom.nextInt(9));
    for (var i = 1; i < length; i++) {
      buffer.write(_idRandom.nextInt(10));
    }
    return buffer.toString();
  }

  /// 请求服务端解密spade_a获取AES key
  Future<String> fetchDecryptKey(String spadeA) async {
    final response = await _dio.post(
      '${ApiConfig.noveBaseUrl}${ApiConfig.algorithmSpade}',
      data: {'spade_a': spadeA},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final decoded = _asJsonMap(response.data);
    if (decoded['code'] != 0) {
      throw ApiException('解密key失败');
    }
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    final key = data['key']?.toString() ?? '';
    if (key.isEmpty || key.length != 32) {
      throw ApiException('无效的解密key');
    }
    return key;
  }

  /// 解析分享口令：把整段剪贴板文本交给服务端 POST /nove/share，
  /// 服务端跟随 302、解码并返回 {videoid, text}。X-Dusa 由 SignInterceptor
  /// 自动签名。返回 (videoId, title)，失败抛 ApiException。
  Future<({String videoId, String? title})> fetchShareInfo(
    String text,
  ) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post(
        '${ApiConfig.noveBaseUrl}${ApiConfig.noveShare}',
        data: {'text': text},
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
    } on DioException catch (e) {
      // 非 2xx（如签名失败 401）默认会抛 DioException，把状态码和服务端
      // 返回体一并暴露出来，便于定位（否则只会看到笼统的“打开失败”）。
      final status = e.response?.statusCode;
      final serverMsg = e.response?.data is Map
          ? (e.response!.data as Map)['message']?.toString()
          : e.response?.data?.toString();
      throw ApiException(
        serverMsg?.isNotEmpty == true
            ? serverMsg!
            : '请求失败：${e.message ?? e.type.name}',
        code: status,
      );
    }
    final decoded = _asJsonMap(response.data);
    if (decoded['code'] != 0) {
      throw ApiException(
        decoded['message']?.toString() ?? '解析分享链接失败',
        code: decoded['code'] is int ? decoded['code'] as int : null,
      );
    }
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    final videoId = data['videoid']?.toString() ?? '';
    if (videoId.isEmpty) throw ApiException('未解析到视频ID');
    final title = data['text']?.toString();
    return (videoId: videoId, title: title?.isNotEmpty == true ? title : null);
  }

  Future<DanmakuResponse> fetchDanmaku({
    required String groupId,
    int? duration,
    int? startOffsetTime,
    String? cursor,
    int count = 90,
  }) async {
    final params = <String, String>{
      'group_id': groupId,
      'count': count.toString(),
      'sort': '1',
    };
    if (duration != null) params['duration'] = duration.toString();
    if (startOffsetTime != null) {
      params['start_offset_time'] = startOffsetTime.toString();
    }
    if (cursor != null && cursor.isNotEmpty) params['cursor'] = cursor;

    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveDanmaku,
      params,
    );
    final response = await _dio.getUri(uri);
    final decoded = _decode(response);
    return DanmakuResponse.fromJson(decoded);
  }

  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) async {
    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveDirectory,
      {'book_id': seriesId},
    );
    final response = await _dio.getUri(uri);
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    final lists = data['lists'] as List? ?? [];
    final chapters = lists.whereType<Map>().map((item) {
      final itemId = item['item_id']?.toString() ?? '';
      final title = item['title']?.toString() ?? '';
      final index = RegExp(r'\d+').firstMatch(title)?.group(0) ?? '0';
      return TheaterChapter(
        itemId: itemId,
        title: title,
        realChapterOrder: index,
      );
    }).toList(growable: false);
    return TheaterEpisodesResult(
      allItemIds: chapters.map((c) => c.itemId).toList(),
      chapters: chapters,
    );
  }

  Future<HomePageResult> fetchHomePage({int? offset, String? sessionId}) async {
    final params = <String, String>{};
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    if (sessionId != null && sessionId.isNotEmpty)
      params['session_id'] = sessionId;

    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveHome,
      params,
    );
    final response = await _dio.getUri(uri);
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    return HomePageResult.fromJson(data);
  }

  // rankType: 'hotplay' | 'recommend' | 'rising' | 'newplay'
  Future<RankListResult> fetchRankList({
    required String rankType,
    String type = 'all',
    String? cellGender,
    int? offset,
    String? sessionId,
  }) async {
    final params = <String, String>{'rank': rankType, 'type': type};
    if (cellGender != null) params['cell_gender'] = cellGender;
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    if (sessionId != null && sessionId.isNotEmpty)
      params['session_id'] = sessionId;

    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveRank,
      params,
    );
    final response = await _dio.getUri(uri);
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    return RankListResult.fromJson(data);
  }

  Future<NewPlayResult> fetchNewPlay({
    int? offset,
    String? sessionId,
    String? cellGender,
  }) async {
    final params = <String, String>{'rank': 'newplay'};
    if (cellGender != null) params['cell_gender'] = cellGender;
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    if (sessionId != null && sessionId.isNotEmpty)
      params['session_id'] = sessionId;

    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveRank,
      params,
    );
    final response = await _dio.getUri(uri);
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    return NewPlayResult.fromJson(data);
  }

  /// 获取滚动公告列表。X-Dusa 由 SignInterceptor 对 api.weeou.com 自动签名。
  Future<List<String>> fetchNotice() async {
    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.notice,
    );
    final response = await _dio.getUri(uri);
    final decoded = _decode(response);
    final data = decoded['data'] as List? ?? [];
    return data.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  }

  Map<String, dynamic> _decode(Response response) {
    if (response.statusCode == null ||
        response.statusCode! < 200 ||
        response.statusCode! >= 300) {
      throw ApiException('请求失败 (${response.statusCode})');
    }
    try {
      final decoded = _asJsonMap(response.data);
      final code = decoded['code'] as int? ?? 0;
      if (code != 0) {
        throw ApiException(decoded['msg']?.toString() ?? '接口异常', code: code);
      }
      return decoded;
    } catch (error) {
      if (error is ApiException) {
        rethrow;
      }
      throw ApiException('解析接口返回失败');
    }
  }

  Map<String, dynamic> _asJsonMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    throw ApiException('解析接口返回失败');
  }
}

class TheaterEpisodesResult {
  TheaterEpisodesResult({required this.allItemIds, required this.chapters});

  final List<String> allItemIds;
  final List<TheaterChapter> chapters;

  /// 播放、预加载和下载共用按目录顺序生成的 1-based 集号。
  /// 标题可能没有数字，不能用标题解析结果作为缓存唯一键。
  List<Episode> toEpisodes() => chapters
      .asMap()
      .entries
      .map((entry) => Episode(
            index: entry.key + 1,
            name: entry.value.title,
            size: 0,
            url: entry.value.itemId,
          ))
      .toList();

  factory TheaterEpisodesResult.fromJson(Map<String, dynamic> json) {
    final allItemIds =
        (json['allItemIds'] as List?)?.map((e) => e.toString()).toList() ?? [];

    final chapterListWithVolume = json['chapterListWithVolume'] as List? ?? [];
    final chapters = <TheaterChapter>[];

    for (final volume in chapterListWithVolume) {
      if (volume is List) {
        for (final chapter in volume) {
          if (chapter is Map) {
            chapters.add(
              TheaterChapter.fromJson(chapter.cast<String, dynamic>()),
            );
          }
        }
      }
    }

    return TheaterEpisodesResult(allItemIds: allItemIds, chapters: chapters);
  }
}

class TheaterChapter {
  TheaterChapter({
    required this.itemId,
    required this.title,
    required this.realChapterOrder,
    this.needPay = 0,
    this.isChapterLock = false,
  });

  final String itemId;
  final String title;
  final String realChapterOrder;
  final int needPay;
  final bool isChapterLock;

  factory TheaterChapter.fromJson(Map<String, dynamic> json) {
    return TheaterChapter(
      itemId: json['itemId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      realChapterOrder: json['realChapterOrder']?.toString() ?? '',
      needPay: json['needPay'] is int ? json['needPay'] as int : 0,
      isChapterLock: json['isChapterLock'] == true,
    );
  }
}

// 首页数据结果
class HomePageResult {
  HomePageResult({
    required this.offset,
    required this.sessionId,
    required this.count,
    required this.hasMore,
    required this.nextOffset,
    required this.list,
  });

  final int offset;
  final String sessionId;
  final int count;
  final bool hasMore;
  final int nextOffset;
  final List<Drama> list;

  factory HomePageResult.fromJson(Map<String, dynamic> json) {
    final list = json['list'] as List? ?? [];
    final dramas = list
        .whereType<Map>()
        .map((item) => Drama.fromHomeJson(item.cast<String, dynamic>()))
        .toList();

    return HomePageResult(
      offset: json['offset'] is int ? json['offset'] as int : 0,
      sessionId: json['session_id']?.toString() ?? '',
      count: json['count'] is int ? json['count'] as int : 0,
      hasMore: json['has_more'] == true,
      nextOffset: json['next_offset'] is int ? json['next_offset'] as int : 0,
      list: dramas,
    );
  }
}

// 榜单数据结果
class RankListResult {
  RankListResult({
    required this.offset,
    required this.sessionId,
    required this.count,
    required this.hasMore,
    required this.nextOffset,
    required this.list,
  });

  final int offset;
  final String sessionId;
  final int count;
  final bool hasMore;
  final int nextOffset;
  final List<Drama> list;

  factory RankListResult.fromJson(Map<String, dynamic> json) {
    final list = json['list'] as List? ?? [];
    final dramas = list
        .whereType<Map>()
        .map((item) => Drama.fromHomeJson(item.cast<String, dynamic>()))
        .toList();

    return RankListResult(
      offset: json['offset'] is int ? json['offset'] as int : 0,
      sessionId: json['session_id']?.toString() ?? '',
      count: json['count'] is int ? json['count'] as int : 0,
      hasMore: json['has_more'] == true,
      nextOffset: json['next_offset'] is int ? json['next_offset'] as int : 0,
      list: dramas,
    );
  }
}

// 新剧数据结果
class NewPlayResult {
  NewPlayResult({
    required this.offset,
    required this.sessionId,
    required this.count,
    required this.hasMore,
    required this.nextOffset,
    required this.list,
  });

  final int offset;
  final String sessionId;
  final int count;
  final bool hasMore;
  final int nextOffset;
  final List<Drama> list;

  factory NewPlayResult.fromJson(Map<String, dynamic> json) {
    final list = json['list'] as List? ?? [];
    final dramas = list
        .whereType<Map>()
        .map((item) => Drama.fromHomeJson(item.cast<String, dynamic>()))
        .toList();

    return NewPlayResult(
      offset: json['offset'] is int ? json['offset'] as int : 0,
      sessionId: json['session_id']?.toString() ?? '',
      count: json['count'] is int ? json['count'] as int : 0,
      hasMore: json['has_more'] == true,
      nextOffset: json['next_offset'] is int ? json['next_offset'] as int : 0,
      list: dramas,
    );
  }
}
