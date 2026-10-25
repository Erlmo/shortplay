import 'drama.dart';

class DramaSeason {
  const DramaSeason(
      {required this.id,
      required this.title,
      required this.cover,
      required this.order,
      required this.episodeCount});

  final int id;
  final String title;
  final String cover;
  final int order;
  final int episodeCount;

  factory DramaSeason.fromJson(Map<String, dynamic> json) => DramaSeason(
        id: int.tryParse(json['series_id']?.toString() ?? '') ?? 0,
        title: json['title']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        order: int.tryParse(json['season_order']?.toString() ?? '') ?? 0,
        episodeCount: int.tryParse(json['episode_cnt']?.toString() ?? '') ?? 0,
      );

  Drama toDrama() => Drama(
      id: id,
      name: title.isEmpty ? '第$order季' : title,
      actors: '',
      cover: cover,
      intro: '',
      tags: const [],
      status: '',
      updateTime: '',
      isTheaterResource: true,
      subTitle: episodeCount > 0 ? '共$episodeCount集' : null);
}

class DramaSeasons {
  const DramaSeasons(
      {required this.albumId,
      required this.currentSeason,
      required this.seasons});

  final String albumId;
  final int currentSeason;
  final List<DramaSeason> seasons;

  factory DramaSeasons.fromJson(Map<String, dynamic> json) {
    final seen = <int>{};
    final seasons = <DramaSeason>[];
    for (final value in json['list'] as List? ?? const []) {
      if (value is! Map) continue;
      final season = DramaSeason.fromJson(value.cast<String, dynamic>());
      if (season.id > 0 && seen.add(season.id)) seasons.add(season);
    }
    seasons.sort((a, b) => a.order.compareTo(b.order));
    return DramaSeasons(
        albumId: json['album_id']?.toString() ?? '',
        currentSeason:
            int.tryParse(json['current_season']?.toString() ?? '') ?? 0,
        seasons: List.unmodifiable(seasons));
  }

  /// 按季序排在 [seasonId] 之后的那一季；当前季不在列表里或已是最后一季时为 null。
  DramaSeason? nextAfter(int seasonId) {
    final index = seasons.indexWhere((season) => season.id == seasonId);
    if (index < 0 || index + 1 >= seasons.length) return null;
    return seasons[index + 1];
  }
}
