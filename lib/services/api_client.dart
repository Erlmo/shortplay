import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import '../models/api_results.dart';
import '../models/app_update.dart';
import '../models/danmaku.dart';
import '../models/drama.dart';
import '../models/drama_season.dart';
import '../models/fq_video.dart';
import '../models/playback_report_book.dart';
import '../models/registered_device.dart';
import '../models/search_suggestion.dart';
import '../models/search_source.dart';
import '../models/search_results.dart';
import '../models/search_series_card.dart';
import 'device_registration_service.dart';
import 'device_request_interceptor.dart';
import 'playback_report_queue.dart';
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
    DeviceRegistrationService? deviceRegistrationService,
  })  : _providedDeviceRegistration = deviceRegistrationService,
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
    // 身份注入必须先于签名，也先于复用 Dio 上已有的业务拦截器。
    _dio.interceptors.insertAll(0, [
      DeviceRequestInterceptor(
        ensureDevice: _deviceRegistration.ensureRequestDevice,
        ensureRegisteredDevice: _requireRegisteredDevice,
        baseUrl: _dio.options.baseUrl,
      ),
      SignInterceptor(targetHost: Uri.parse(_dio.options.baseUrl).host),
    ]);
    _deviceRegistration.addListener(_onDeviceRegistered);
  }

  final Dio _dio;
  final DeviceRegistrationService? _providedDeviceRegistration;
  late final DeviceRegistrationService _deviceRegistration =
      _providedDeviceRegistration ??
          DeviceRegistrationService(registerDevice: _registerDevice);
  final Map<String, Drama> _dramaCache = {};
  final ValueNotifier<int> deviceRevision = ValueNotifier(0);
  bool _disposed = false;
  late final PlaybackReportQueue playbackReports = PlaybackReportQueue(
    sender: reportPlaybackBooks,
    currentOwner: () async {
      final device = await _deviceRegistration.readCachedDevice();
      return device == null ? null : _deviceOwner(device);
    },
    verifiedOwner: () async => _deviceOwner(await _requireRegisteredDevice()),
  );

  /// 暴露已配置 SignInterceptor 的 Dio，供 ShareLinkResolver 等复用同一签名链路。
  Dio get dio => _dio;

  /// 启动时提前准备设备；所有业务请求复用同一个注册任务。
  Future<void> initializeDevice() async {
    await _deviceRegistration.ensureRequestDevice();
    unawaited(playbackReports.flush());
  }

  /// 前台恢复时立即尝试补办注册，其余时间由服务内部退避重试。
  Future<void> retryDeviceRegistration() =>
      _deviceRegistration.retryRegistration();

  void _onDeviceRegistered() {
    if (_disposed) return;
    deviceRevision.value++;
    unawaited(playbackReports.flush(force: true));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _deviceRegistration.removeListener(_onDeviceRegistered);
    if (_providedDeviceRegistration == null) _deviceRegistration.dispose();
    _dio.close(force: true);
    deviceRevision.dispose();
  }

  static String _deviceOwner(RegisteredDevice device) =>
      '${device.deviceId}:${device.installId}';

  Future<void> reportPlaybackBooks(
    List<PlaybackReportBook> books,
    String owner,
  ) async {
    if (books.isEmpty || books.length > PlaybackReportQueue.maxBatchSize) {
      throw ApiException('观看记录批次无效');
    }
    final device = await _requireRegisteredDevice();
    if (_deviceOwner(device) != owner) {
      throw ApiException('观看记录所属设备已变更');
    }
    final response = await _dio.post(
      ApiConfig.playbackReport,
      data: {
        'books': books.map((book) => book.toJson()).toList(),
        'write_mode': 1
      },
    );
    final data = _decode(response)['data'];
    if (data is! Map ||
        data['accepted'] != true ||
        data['count'] != books.length) {
      throw ApiException('观看记录尚未确认同步');
    }
  }

  Future<RegisteredDevice> _requireRegisteredDevice() async {
    try {
      final device = await _deviceRegistration.readCachedDevice();
      if (device == null) {
        throw ApiException('独立设备尚未注册，观看记录已保留，稍后同步');
      }
      return device;
    } on DeviceRegistrationException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<Map<String, dynamic>> _registerDevice() async {
    try {
      final response = await _dio.post(ApiConfig.deviceRegister);
      final data = _decode(response)['data'];
      if (data is! Map<String, dynamic>) {
        throw ApiException('设备注册信息无效，请稍后重试');
      }
      return data;
    } on DioException {
      throw ApiException('连接设备注册服务失败，请稍后重试');
    }
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

  /// 请求番茄官方API获取加密视频信息
  Future<List<FqVideoItem>> fetchFqVideoModel(String videoId) async {
    final requestTimer = Stopwatch()..start();
    final device = await _deviceRegistration.ensureRequestDevice();
    // 一次安装的所有接口共用身份；签名与实际视频请求使用完全相同的 URL。
    final fullUrl = Uri.https(
      ApiConfig.fqVideoHost,
      ApiConfig.fqVideoPath,
      {
        'iid': device.installId,
        'device_id': device.deviceId,
        'aid': ApiConfig.fqAid,
        'version_code': '72132',
        'version_name': '7.2.1.32',
        'update_version_code': '72132',
        'device_brand': device.deviceBrand,
        'device_type': device.deviceModel,
        'os_version': device.osVersion,
        'device_platform': 'android',
        'cdid': device.cdid,
      },
    ).toString();

    final candidates = await _requestFqVideoModel(videoId, fullUrl, device);
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
        device,
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
    String fullUrl,
    RegisteredDevice device, {
    CancelToken? cancelToken,
  }) async {
    // 1. 获取算法签名
    final signResponse = await _dio.post(
      ApiConfig.algorithmSign,
      data: {'url': fullUrl},
      cancelToken: cancelToken,
      options: Options(
        headers: {'Content-Type': 'application/json'},
        extra: {DeviceRequestInterceptor.deviceSnapshotKey: device},
      ),
    );
    final signDecoded = _asJsonMap(signResponse.data);
    if (signDecoded['code'] != 0) {
      throw ApiException('算法签名失败');
    }
    final signData = signDecoded['data'] as Map<String, dynamic>? ?? {};

    // 2. 请求番茄视频API
    final fqHeaders = <String, String>{
      'Host': ApiConfig.fqVideoHost,
      'user-agent': _videoUserAgent(fullUrl),
      'Cookie': 'install_id=${Uri.parse(fullUrl).queryParameters['iid']}',
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

  String _videoUserAgent(String url) {
    final query = Uri.parse(url).queryParameters;
    return 'com.dragon.read/72132 (Linux; U; Android ${query['os_version']}; '
        'zh_CN; ${query['device_type']}; Build/TKQ1.221114.001; '
        'Cronet/TTNetVersion:04657795 2026-01-23 '
        'QuicVersion:c67e9834 2025-09-08)';
  }

  /// 请求服务端解密spade_a获取AES key
  Future<String> fetchDecryptKey(String spadeA) async {
    final response = await _dio.post(
      ApiConfig.algorithmSpade,
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
