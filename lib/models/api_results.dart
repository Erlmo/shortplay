import 'drama.dart';
import 'episode.dart';

// ApiClient 的分页 / 目录类响应 DTO。由 services/api_client.dart 统一导出，
// 原有 `import '../services/api_client.dart'` 的代码无需改动。

class TheaterEpisodesResult {
  TheaterEpisodesResult({
    required this.allItemIds,
    required this.chapters,
    this.bookInfo,
  });

  final List<String> allItemIds;
  final List<TheaterChapter> chapters;

  /// 服务端随目录一起返回的短剧信息（旧版服务端没有这个字段时为 null）
  final Drama? bookInfo;

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
