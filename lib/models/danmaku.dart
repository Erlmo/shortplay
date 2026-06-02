import 'dart:convert';

class DanmakuComment {
  final String id;
  final String content;
  final int offsetMs;
  int fireAtMs;
  final int createTime;
  final String userId;

  DanmakuComment({
    required this.id,
    required this.content,
    required this.offsetMs,
    this.fireAtMs = 0,
    required this.createTime,
    required this.userId,
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
  const DanmakuResponse({
    required this.cursor,
    required this.hasMore,
    required this.total,
    required this.comments,
  });
  int get endOffsetMs {
    if (cursor.isEmpty) return 0;
    try {
      final map = jsonDecode(cursor) as Map<String, dynamic>;
      final val = map['end_offset_time'];
      if (val is int) return val;
      return int.tryParse(val?.toString() ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  factory DanmakuResponse.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? {};
    final listInfo = data['common_list_info'] as Map<String, dynamic>? ?? {};
    final dataList = data['data_list'] as List? ?? [];

    return DanmakuResponse(
      cursor: listInfo['cursor']?.toString() ?? '',
      hasMore: listInfo['has_more'] == true,
      total: _parseTotal(listInfo['total']),
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
