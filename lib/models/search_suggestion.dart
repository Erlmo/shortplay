import 'drama.dart';
import 'search_source.dart';

class SearchHighlightRange {
  const SearchHighlightRange(this.start, this.length);

  final int start;
  final int length;
}

class SearchSuggestion {
  const SearchSuggestion({
    required this.name,
    this.keyword = '',
    this.source = SearchSource.comic,
    this.searchSourceId = '',
    this.clientExtra = '',
    this.highlights = const [],
    this.cover = '',
    this.drama,
    this.canPlay = false,
    this.hasPlayButton = false,
    this.isRich = false,
  });

  final String name;
  final String keyword;
  final SearchSource source;
  final String searchSourceId;
  final String clientExtra;
  final List<SearchHighlightRange> highlights;
  final String cover;
  final Drama? drama;
  final bool canPlay;
  final bool hasPlayButton;
  final bool isRich;

  bool get showPlayButton => canPlay && hasPlayButton && drama != null;

  factory SearchSuggestion.fromJson(Map<String, dynamic> json,
      {bool allowRich = true, SearchSource source = SearchSource.comic}) {
    final name = json['name']?.toString() ?? '';
    final keyword = json['keyword']?.toString() ?? '';
    final video = _map(json['video_data']);
    final detail = _map(video['video_detail']);
    // 原生播放读取video_data.series_id；keyword仅保留为联想来源。
    var id = 0;
    for (final value in [
      video['series_id'],
      detail['series_id'],
    ]) {
      final candidate = int.tryParse(value?.toString() ?? '') ?? 0;
      if (candidate <= 0) continue;
      id = candidate;
      break;
    }
    final isRich = allowRich && json['show_type'] == 3;
    final canPlay = allowRich && json['can_play'] == true;
    final rawCover =
        video['cover']?.toString() ?? json['pic_url']?.toString() ?? '';
    final cover =
        rawCover.startsWith('https://') || rawCover.startsWith('http://')
            ? rawCover
            : '';
    Drama? drama;
    if (id > 0) {
      drama = Drama.fromTheaterSearchJson({
        ...video,
        'title': video['title'] ?? name,
        'cover': cover,
        'video_detail': {...detail, 'series_id': id},
      });
    }
    final rawHighlights = json['display_high_light'];
    final highlight = rawHighlights is List && rawHighlights.isNotEmpty
        ? _map(rawHighlights.first)
        : _map(json['search_high_light']);
    final ranges = <SearchHighlightRange>[];
    final positions = highlight['high_light_position'];
    if (positions is List && highlight['text'] == name) {
      for (final position in positions) {
        if (position is! List || position.length != 2) continue;
        final start = int.tryParse(position[0].toString());
        final length = int.tryParse(position[1].toString());
        if (start == null ||
            length == null ||
            start < 0 ||
            length <= 0 ||
            start + length > name.length) {
          continue;
        }
        ranges.add(SearchHighlightRange(start, length));
      }
    }
    ranges.sort((a, b) => a.start.compareTo(b.start));
    return SearchSuggestion(
      name: name,
      keyword: keyword,
      source: source,
      searchSourceId: json['search_source_id']?.toString() ?? '',
      clientExtra: json['client_extra']?.toString() ?? '',
      highlights: ranges,
      cover: cover,
      drama: drama,
      canPlay: canPlay,
      hasPlayButton: json['has_play_button'] == true,
      isRich: isRich,
    );
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};
}

class SearchSuggestionResult {
  const SearchSuggestionResult({required this.query, required this.items});

  final String query;
  final List<SearchSuggestion> items;

  factory SearchSuggestionResult.fromJson(Map<String, dynamic> json,
      {SearchSource source = SearchSource.comic}) {
    final rich = json['query_result_v2'];
    final plain = json['query_result'];
    final items = <SearchSuggestion>[];
    if (rich is List && rich.isNotEmpty) {
      for (final item in rich) {
        if (item is Map<String, dynamic>) {
          final parsed = SearchSuggestion.fromJson(item,
              allowRich: json['use_rich'] == true, source: source);
          if (parsed.name.trim().isNotEmpty) items.add(parsed);
        }
      }
    } else if (plain is List) {
      for (final item in plain) {
        if (item is String && item.trim().isNotEmpty) {
          items.add(SearchSuggestion(name: item, source: source));
        }
      }
    }
    return SearchSuggestionResult(
      query: json['query_key']?.toString() ?? '',
      items: items,
    );
  }
}
