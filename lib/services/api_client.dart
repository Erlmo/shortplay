import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/api_config.dart';
import '../models/api_results.dart';
import '../models/app_update.dart';
import '../models/danmaku.dart';
import '../models/drama.dart';
import '../models/drama_season.dart';
import '../models/fq_video.dart';
import '../models/search_suggestion.dart';
import '../models/search_source.dart';
import '../models/search_results.dart';
import '../models/search_series_card.dart';
import 'sign_interceptor.dart';

export '../models/api_results.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => 'ApiException(message: $message, code: $code)';
}

class ApiClient {
  ApiClient({
    Dio? dio,
    String? baseUrl,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? ApiConfig.noveBaseUrl,
                connectTimeout: ApiConfig.connectTimeout,
                receiveTimeout: ApiConfig.receiveTimeout,
                sendTimeout: ApiConfig.sendTimeout,
              ),
            ) {
    if (_dio.options.baseUrl.isEmpty) {
      _dio.options.baseUrl = baseUrl ?? ApiConfig.noveBaseUrl;
    }
    _dio.interceptors.insert(
      0,
      SignInterceptor(targetHost: Uri.parse(_dio.options.baseUrl).host),
    );
  }

  final Dio _dio;
  final DateTime Function() _clock;
  final Map<String, Drama> _dramaCache = {};
  bool _disposed = false;
  final Map<String, ({String key, DateTime? expire})> _resolvedDecryptKeys = {};
  final Map<String, Future<List<FqVideoItem>>> _videoRequests = {};

  /// 暴露已配置 SignInterceptor 的 Dio，供 ShareLinkResolver 等复用同一签名链路。
  Dio get dio => _dio;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _dio.close(force: true);
  }

  Future<AppUpdate?> checkAppUpdate({
    required String device,
    required String version,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get(
        ApiConfig.appUpdate,
        queryParameters: {'device': device, 'version': version},
        cancelToken: cancelToken,
      );
      final decoded = _decode(response);
      final data = decoded['data'];
      if (data is! Map<String, dynamic>) {
        throw ApiException('更新信息无效，请稍后重试');
      }
      return AppUpdate.fromResponse(data);
    } on FormatException {
      throw ApiException('更新信息无效，请稍后重试');
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw ApiException('连接更新服务失败，请稍后重试');
    }
  }

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

  Future<SearchSuggestionResult> fetchSearchSuggestions(
    String keyword, {
    CancelToken? cancelToken,
    SearchSource source = SearchSource.comic,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) {
      return const SearchSuggestionResult(query: '', items: []);
    }
    try {
      final response = await _dio.get(
        ApiConfig.noveSearchSuggest,
        queryParameters: {'key': query, 'source': source.value},
        cancelToken: cancelToken,
      );
      final data = _decode(response)['data'];
      if (data is! Map<String, dynamic>) {
        throw ApiException('解析搜索联想失败');
      }
      return SearchSuggestionResult.fromJson(data, source: source);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw ApiException('搜索联想暂不可用，可直接输入片名搜索');
    }
  }

  Future<SearchResultsResponse> searchResults(
    SearchQuery query, {
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get(
        ApiConfig.noveSearch,
        queryParameters: query.toQueryParameters(),
        cancelToken: cancelToken,
      );
      final decoded = _decode(response);
      if (decoded['search_tabs'] is! List) {
        throw ApiException('搜索返回格式错误，请更新服务端后重试');
      }
      return SearchResultsResponse.fromJson(decoded, source: query.source);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw ApiException('搜索失败，请检查网络后重试');
    }
  }

  /// 657 系列卡按原搜索详情协议加载当前季，不另查关联季目录。
  Future<List<SearchSeriesEpisode>> fetchSearchSeason(
    String seriesId, {
    SearchSource source = SearchSource.comic,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get(
        ApiConfig.noveSearchSeason,
        queryParameters: {'source': source.value, 'series_id': seriesId},
        cancelToken: cancelToken,
      );
      final data = _decode(response)['data'];
      final video = data is Map ? data['video_data'] : null;
      final rawEpisodes = video is Map ? video['video_list'] : null;
      if (rawEpisodes is! List) throw ApiException('当前季的集数信息无效');
      final episodes = <SearchSeriesEpisode>[];
      for (final raw in rawEpisodes) {
        if (raw is! Map) continue;
        final episode =
            SearchSeriesEpisode.tryParse(raw.cast<String, dynamic>());
        if (episode != null && episode.seriesId == seriesId) {
          episodes.add(episode);
        }
      }
      if (episodes.isEmpty) throw ApiException('当前季暂无可播放集数');
      return List.unmodifiable(episodes);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw ApiException('加载当前季失败，请稍后重试');
    }
  }

  /// 保留旧调用入口；新搜索页使用包含分类、分组与游标的完整响应。
  Future<({List<Drama> dramas, bool hasMore})> search(
    String keyword, {
    int offset = 0,
  }) async {
    final result =
        await searchResults(SearchQuery(query: keyword, offset: offset));
    final tab = result.primaryTab;
    return (
      dramas:
          tab?.groups.expand((group) => group.entries).toList() ?? <Drama>[],
      hasMore: tab?.hasMore ?? false,
    );
  }

  /// 视频解析完全由服务端处理；客户端只发送视频ID，视频流仍直连CDN。
  Future<List<FqVideoItem>> fetchFqVideoModel(String videoId) async {
    final id = videoId.trim();
    if (id.isEmpty) throw ApiException('缺少视频编号');
    final pending = _videoRequests[id];
    if (pending != null) return pending;
    final request = _resolveVideo(id);
    _videoRequests[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_videoRequests[id], request)) _videoRequests.remove(id);
    }
  }

  Future<List<FqVideoItem>> _resolveVideo(String videoId) async {
    try {
      final response = await _dio.post(
        ApiConfig.algorithmVideo,
        data: {'video_id': videoId},
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      final decoded = _decode(response);
      final data = _asJsonMap(decoded['data']);
      final raw = data['streams'];
      if (raw is! List) throw ApiException('视频解析结果无效');
      final items = <FqVideoItem>[];
      for (final entry in raw.whereType<Map>()) {
        final item = FqVideoItem.fromJson(entry.cast<String, dynamic>());
        final uri = Uri.tryParse(item.url);
        if (uri == null ||
            !['https', 'http'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(item.decryptKey) ||
            item.spadeA.isEmpty ||
            item.codec == 'bytevc2' ||
            item.codec == 'bvc2') {
          continue;
        }
        if (item.expiresAt != null && !item.expiresAt!.isAfter(_clock())) {
          continue;
        }
        item.posterUrl = data['poster_url']?.toString() ?? '';
        items.add(item);
        _resolvedDecryptKeys.remove(item.spadeA);
        _resolvedDecryptKeys[item.spadeA] =
            (key: item.decryptKey, expire: item.expiresAt);
      }
      while (_resolvedDecryptKeys.length > 256) {
        _resolvedDecryptKeys.remove(_resolvedDecryptKeys.keys.first);
      }
      if (items.isEmpty) throw ApiException('未获取到有效播放地址');
      return items;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      final status = error.response?.statusCode;
      if (status == 404 || status == 405) {
        throw ApiException('播放解析服务需要更新，请先更新服务端', code: status);
      }
      final body = error.response?.data;
      throw ApiException(
          body is Map
              ? body['message']?.toString() ?? '视频解析失败，请稍后重试'
              : '视频解析失败，请稍后重试',
          code: status);
    } on FormatException {
      throw ApiException('视频解析结果无效');
    } on TypeError {
      throw ApiException('视频解析结果无效');
    }
  }

  /// 请求服务端解密spade_a获取AES key
  Future<String> fetchDecryptKey(String spadeA) async {
    final resolved = _resolvedDecryptKeys[spadeA];
    if (resolved != null) {
      if (resolved.expire != null && !resolved.expire!.isAfter(_clock())) {
        _resolvedDecryptKeys.remove(spadeA);
        throw ApiException('播放地址已过期，请重新解析');
      }
      return resolved.key;
    }

    final response = await _dio.post(
      ApiConfig.algorithmSpade,
      data: {'spade_a': spadeA},
      options: Options(
        headers: {'Content-Type': 'application/json'},
      ),
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
        ApiConfig.noveShare,
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
    String? bookId,
    int? duration,
    int? startOffsetTime,
    String? cursor,
    int count = 90,
    CancelToken? cancelToken,
  }) async {
    final params = <String, String>{
      'group_id': groupId,
      'count': count.toString(),
      'sort': '1',
    };
    if (bookId != null && bookId.isNotEmpty) params['book_id'] = bookId;
    if (duration != null) params['duration'] = duration.toString();
    if (startOffsetTime != null) {
      params['start_offset_time'] = startOffsetTime.toString();
    }
    if (cursor != null && cursor.isNotEmpty) params['cursor'] = cursor;

    final response = await _dio.get(ApiConfig.noveDanmaku,
        queryParameters: params, cancelToken: cancelToken);
    final decoded = _decode(response);
    return DanmakuResponse.fromJson(decoded);
  }

  /// 目录结果短暂缓存：分享识别时先取一次详情，紧接着播放页又取一次目录，
  /// 两分钟内同一部剧复用同一份结果，不重复请求。
  final Map<String, ({DateTime at, Future<TheaterEpisodesResult> result})>
      _directoryCache = {};

  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) {
    final cached = _directoryCache[seriesId];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 2)) {
      return cached.result;
    }
    final future = _fetchTheaterEpisodes(seriesId);
    _directoryCache[seriesId] = (at: DateTime.now(), result: future);
    // 失败不缓存，下次重新请求
    future.catchError((Object _) {
      _directoryCache.remove(seriesId);
      return TheaterEpisodesResult(allItemIds: const [], chapters: const []);
    });
    return future;
  }

  Future<TheaterEpisodesResult> _fetchTheaterEpisodes(String seriesId) async {
    final response = await _dio
        .get(ApiConfig.noveDirectory, queryParameters: {'book_id': seriesId});
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    final lists = data['lists'] as List? ?? [];
    final chapters =
        lists.whereType<Map>().toList().asMap().entries.map((entry) {
      final item = entry.value;
      final itemId = item['item_id']?.toString() ?? '';
      final episodeTitle = item['episode_title']?.toString().trim() ?? '';
      final title = episodeTitle.isNotEmpty
          ? episodeTitle
          : item['title']?.toString() ?? '';
      final index = (entry.key + 1).toString();
      return TheaterChapter(
        itemId: itemId,
        title: title,
        realChapterOrder: index,
      );
    }).toList(growable: false);
    final rawInfo = data['book_info'];
    Drama? bookInfo;
    if (rawInfo is Map) {
      final info = Drama.fromTheaterDetailJson(rawInfo.cast<String, dynamic>());
      if (info.id > 0 && info.name.isNotEmpty) bookInfo = info;
    }
    return TheaterEpisodesResult(
      allItemIds: chapters.map((c) => c.itemId).toList(),
      chapters: chapters,
      bookInfo: bookInfo,
    );
  }

  Future<Map<String, String>> fetchEpisodeTitles(String seriesId) async {
    try {
      final response = await _dio
          .get('/nove/episodetitles', queryParameters: {'book_id': seriesId});
      final data = _decode(response)['data'];
      if (data is! Map || data['titles'] is! Map) {
        throw ApiException('分集标题数据无效');
      }
      if (data['series_id'] != null &&
          data['series_id'].toString() != seriesId) {
        throw ApiException('分集标题与当前短剧不匹配');
      }
      return {
        for (final entry in (data['titles'] as Map).entries)
          if (entry.value is String &&
              (entry.value as String).trim().isNotEmpty)
            entry.key.toString(): (entry.value as String).trim()
      };
    } on DioException catch (error) {
      final body = error.response?.data;
      throw ApiException(body is Map
          ? body['message']?.toString() ?? '分集标题加载失败'
          : '分集标题加载失败，请稍后重试');
    }
  }

  Future<DramaSeasons> fetchDramaSeasons(String seriesId,
      {CancelToken? cancelToken}) async {
    try {
      final response = await _dio.get(ApiConfig.noveSeasons,
          queryParameters: {'book_id': seriesId}, cancelToken: cancelToken);
      final decoded = _decode(response);
      final data = decoded['data'];
      if (data is! Map<String, dynamic>) {
        throw ApiException('其他季数据无效');
      }
      return DramaSeasons.fromJson(data);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw ApiException('无法加载其他季，请检查服务端接口或稍后重试');
    }
  }

  /// 按短剧 ID 取详情（封面 / 简介 / 标签 / 评分 / 集数等）。
  /// 详情跟着剧集列表接口 /nove/directory 一起返回；取不到时返回 null。
  Future<Drama?> fetchBookInfo(String bookId) async =>
      (await fetchTheaterEpisodes(bookId)).bookInfo;

  Future<HomePageResult> fetchHomePage({int? offset, String? sessionId}) async {
    final params = <String, String>{};
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    if (sessionId != null && sessionId.isNotEmpty) {
      params['session_id'] = sessionId;
    }
    final response = await _dio.get(
      ApiConfig.noveHome,
      queryParameters: params,
    );
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    return HomePageResult.fromJson(data);
  }

  // rankType: 'hotplay' | 'recommend' | 'followed' | 'hotsearch' | 'newplay' | 'newrank'
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

    late final Response response;
    try {
      response = await _dio.get(ApiConfig.noveRank, queryParameters: params);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      final body = error.response?.data;
      final message = body is Map ? body['message'] ?? body['msg'] : null;
      throw ApiException(message is String ? message : '榜单加载失败，请稍后重试',
          code: error.response?.statusCode);
    }
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

    final response =
        await _dio.get(ApiConfig.noveRank, queryParameters: params);
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    return NewPlayResult.fromJson(data);
  }

  /// 获取滚动公告列表。X-Dusa 由 SignInterceptor 对 api.weeou.com 自动签名。
  Future<List<String>> fetchNotice() async {
    final response = await _dio.get(ApiConfig.notice);
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
        throw ApiException(
            decoded['msg']?.toString() ??
                decoded['message']?.toString() ??
                '接口异常',
            code: code);
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
