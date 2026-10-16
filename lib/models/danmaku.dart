import 'dart:convert';

class DanmakuComment {
  final String id;
  final String content;
  final int offsetMs;
  int fireAtMs;
  final int createTime;
  final String userId;
  final int showBoost;
  final bool forceInsert;

  DanmakuComment({
    required this.id,
    required this.content,
    required this.offsetMs,
    this.fireAtMs = 0,
    required this.createTime,
    required this.userId,
    this.showBoost = 0,
    this.forceInsert = false,
  });

  factory DanmakuComment.fromDataItem(Map<String, dynamic> item) {
    final comment = item['comment'] as Map<String, dynamic>? ?? {};
    final common = comment['common'] as Map<String, dynamic>? ?? {};
    final expand = comment['expand'] as Map<String, dynamic>? ?? {};
    final contentMap = common['content'] as Map<String, dynamic>? ?? {};
    final userInfo = common['user_info'] as Map<String, dynamic>? ?? {};
    return DanmakuComment(
      id: comment['comment_id']?.toString() ?? '',
      content: contentMap['text']?.toString() ?? '',
      offsetMs: _parseInt(expand['offset_time']),
      createTime: _parseInt(common['create_timestamp']),
      userId: userInfo['user_id']?.toString() ?? '',
      showBoost: _parseInt(expand['show_boost']),
      forceInsert: expand['is_force_insert_danmaku'] == true,
    );
  }

  static int _parseInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class DanmakuResponse {
  final String cursor;
  final bool hasMore;
  final int total;
  final List<DanmakuComment> comments;

  /// APK CommentListExtra.nextQueryDanmakuListTime，单位为毫秒。
  /// 缺失时才兼容旧响应的 cursor.end_offset_time。
  final int? nextQueryTimeMs;
  const DanmakuResponse({
    required this.cursor,
    required this.hasMore,
    required this.total,
    required this.comments,
    this.nextQueryTimeMs,
  });
  int get endOffsetMs {
    if (nextQueryTimeMs != null) return nextQueryTimeMs!;
    return cachedEndOffsetMs ?? 0;
  }

  int? get cachedStartOffsetMs => _cursorOffset('start_offset_time');
  int? get cachedEndOffsetMs => _cursorOffset('end_offset_time');

  int? _cursorOffset(String key) {
    if (cursor.isEmpty) return null;
    try {
      final map = jsonDecode(cursor) as Map<String, dynamic>;
      final val = map[key];
      if (val is int) return val;
      return int.tryParse(val?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }

  factory DanmakuResponse.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? {};
    final listInfo = data['common_list_info'] as Map<String, dynamic>? ?? {};
    final dataList = data['data_list'] as List? ?? [];
    final extra = data['extra'] as Map<String, dynamic>? ?? {};

    return DanmakuResponse(
      cursor: listInfo['cursor']?.toString() ?? '',
      hasMore: listInfo['has_more'] == true,
      total: _parseTotal(listInfo['total']),
      nextQueryTimeMs:
          int.tryParse(extra['next_query_danmaku_list_time']?.toString() ?? ''),
      comments: dataList
          .whereType<Map<String, dynamic>>()
          .map((item) => DanmakuComment.fromDataItem(item))
          .toList(),
    );
  }

  static int _parseTotal(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
