import 'drama.dart';

enum SearchSeriesItemKind { video, book, upcoming }

/// 红果漫剧 655 保留 658 模块，656 保留根节点的 659 横排。
class SearchSeriesCardData {
  const SearchSeriesCardData({
    required this.title,
    required this.groups,
    required this.initialGroupIndex,
    this.subtitle = '',
    this.showType = 655,
    this.v3,
  });

  final String title;
  final List<SearchSeriesGroup> groups;
  final int initialGroupIndex;
  final String subtitle;
  final int showType;
  int get sourceType => showType;
  final SearchSeriesV3Data? v3;

  static SearchSeriesCardData? tryParse(Map<String, dynamic> raw) {
    final showType = _number(raw['show_type']);
    if (showType == 657) {
      final card = SearchSeriesV3Data.tryParse(raw);
      if (card == null) return null;
      return SearchSeriesCardData(
        title: card.title,
        subtitle: card.subtitle,
        showType: 657,
        groups: const [],
        initialGroupIndex: 0,
        v3: card,
      );
    }
    // 657 有不同原生模型，不能套用封面横排。
    if (showType != 655 && showType != 656) return null;
    if (showType == 656) {
      final items = <SearchSeriesCardItem>[];
      final indices = <int>[];
      final cells = _maps(raw['cell_data']);
      for (var index = 0; index < cells.length; index++) {
        final item = SearchSeriesCardItem.tryParse(cells[index], index);
        if (item == null) continue;
        items.add(item);
        indices.add(index);
      }
      if (items.isEmpty) return null;
      return SearchSeriesCardData(
        showType: 656,
        title: _highlight(raw, 'cell_name', _text(raw['cell_name'])),
        subtitle: _text(raw['cell_abstract']),
        groups: [
          SearchSeriesGroup(
            title: '',
            items: List.unmodifiable(items),
            initialItemIndex:
                _selected(raw['search_ip_card_selected_idx'], indices),
          ),
        ],
        initialGroupIndex: 0,
      );
    }
    final groups = <SearchSeriesGroup>[];
    final originalIndices = <int>[];
    final cells = _maps(raw['cell_data']);
    for (var index = 0; index < cells.length; index++) {
      final cell = cells[index];
      if (_number(cell['show_type']) != 658) continue;
      final items = <SearchSeriesCardItem>[];
      final itemIndices = <int>[];
      final children = _maps(cell['cell_data']);
      for (var itemIndex = 0; itemIndex < children.length; itemIndex++) {
        final item =
            SearchSeriesCardItem.tryParse(children[itemIndex], itemIndex);
        if (item == null) continue;
        items.add(item);
        itemIndices.add(itemIndex);
      }
      if (items.isEmpty) continue;
      originalIndices.add(index);
      groups.add(SearchSeriesGroup(
        title: _text(cell['cell_name']),
        items: List.unmodifiable(items),
        initialItemIndex:
            _selected(cell['search_ip_card_selected_idx'], itemIndices),
      ));
    }
    if (groups.isEmpty) return null;
    return SearchSeriesCardData(
      title: _highlight(raw, 'cell_name', _text(raw['cell_name'])),
      groups: List.unmodifiable(groups),
      initialGroupIndex:
          _selected(raw['search_ip_card_selected_idx'], originalIndices),
    );
  }
}

class SearchSeriesGroup {
  const SearchSeriesGroup({
    required this.title,
    required this.items,
    required this.initialItemIndex,
  });

  final String title;
  final List<SearchSeriesCardItem> items;
  final int initialItemIndex;
}

class SearchSeriesCardItem {
  const SearchSeriesCardItem({
    required this.id,
    required this.sourceIndex,
    required this.kind,
    required this.title,
    required this.displayTitle,
    required this.cover,
    required this.subtitle,
    required this.raw,
    this.drama,
    this.routeUrl = '',
  });

  final String id;
  final int sourceIndex;
  final SearchSeriesItemKind kind;
  final String title;
  final String displayTitle;
  final String cover;
  final String subtitle;
  final Drama? drama;
  final Map<String, dynamic> raw;
  final String routeUrl;

  String get key => '${kind.name}:$id:$sourceIndex';

  static SearchSeriesCardItem? tryParse(Map<String, dynamic> cell, int index) {
    if (_number(cell['show_type']) != 659) return null;
    final type = _number(cell['search_ip_card_content_type']);
    final field = switch (type) {
      0 => 'book_data',
      2 => 'video_data',
      21 => 'subscribe_items',
      _ => null,
    };
    if (field == null) return null;
    final data = _maps(cell[field]);
    if (data.isEmpty) return null;
    final first = data.first;
    final id = _text(first[switch (type) {
      0 => 'book_id',
      2 => 'series_id',
      _ => 'item_id',
    }]);
    if (id.trim().isEmpty || (type == 21 && (int.tryParse(id) ?? 0) <= 0)) {
      return null;
    }
    final title = _text(first[switch (type) {
      0 => 'book_name',
      2 => 'title',
      _ => 'name',
    }]);
    final detail = _map(first['video_detail']);
    final bookThumb = _text(first['thumb_url']);
    final episodeCount = _number(first['episode_cnt']) ?? 0;
    // 搜索使用顶层 series_id；旧 Drama 工厂只读取 video_detail 中的 ID。
    final drama = type == 2 && (int.tryParse(id) ?? 0) > 0
        ? Drama.fromTheaterSearchJson({
            ...first,
            'video_detail': {...detail, 'series_id': id},
          })
        : null;
    return SearchSeriesCardItem(
      id: id,
      sourceIndex: index,
      kind: switch (type) {
        0 => SearchSeriesItemKind.book,
        2 => SearchSeriesItemKind.video,
        _ => SearchSeriesItemKind.upcoming,
      },
      title: title,
      displayTitle: _highlight(cell, 'title', title),
      cover: type == 0
          ? (bookThumb.trim().isEmpty ? _text(first['thumb_pic']) : bookThumb)
          : _text(first['cover']),
      subtitle: type == 21
          ? _text(first['sub_info'])
          : type == 0
              ? _maps(first['secondary_info_list'])
                  .map((info) => _text(info['content']))
                  .where((content) => content.trim().isNotEmpty)
                  .join('·')
              : episodeCount > 0
                  ? '共$episodeCount集'
                  : '',
      drama: drama,
      routeUrl: type == 21
          ? (_text(first['schema']).trim().isNotEmpty
              ? _text(first['schema'])
              : _text(first['detail_schema']))
          : '',
      raw: Map.unmodifiable(cell),
    );
  }
}

int _selected(Object? selected, List<int> indices) {
  final found = indices.indexOf(_number(selected) ?? 0);
  return found < 0 ? 0 : found;
}

String _highlight(Map<String, dynamic> raw, String key, String fallback) {
  final text = _text(_map(_map(raw['search_high_light'])[key])['text']);
  return text.trim().isEmpty ? fallback : text;
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList()
    : const [];

String _text(Object? value) => value?.toString() ?? '';
int? _number(Object? value) => int.tryParse(_text(value));

class SearchSeriesV3Data {
  const SearchSeriesV3Data({
    required this.title,
    required this.subtitle,
    required this.seasons,
    required this.initialSeasonIndex,
  });

  final String title;
  final String subtitle;
  final List<SearchSeriesSeason> seasons;
  final int initialSeasonIndex;

  static SearchSeriesV3Data? tryParse(Map<String, dynamic> raw) {
    if (_number(raw['show_type']) != 657) return null;
    final seasons = <SearchSeriesSeason>[];
    final indices = <int>[];
    final cells = _maps(raw['cell_data']);
    for (var index = 0; index < cells.length; index++) {
      final cell = cells[index];
      if (_number(cell['show_type']) != 658) continue;
      final docs = _maps(cell['cell_data']);
      if (docs.any((doc) =>
          _number(doc['show_type']) == 659 &&
          _number(doc['search_ip_card_content_type']) == 0)) {
        continue;
      }
      final videos = _maps(cell['video_data']);
      Map<String, dynamic> video = videos.isEmpty ? const {} : videos.first;
      if (_text(video['series_id']).trim().isEmpty ||
          _text(video['cover']).trim().isEmpty) {
        video = const {};
      }
      Map<String, dynamic> subscription = const {};
      for (final type in [21, 14]) {
        final matching = docs.where((doc) =>
            _number(doc['show_type']) == 659 &&
            _number(doc['search_ip_card_content_type']) == type);
        if (matching.isNotEmpty) {
          final items = _maps(matching.first['subscribe_items']);
          if (items.isNotEmpty) subscription = items.first;
          break;
        }
      }
      if (subscription.isEmpty) {
        final items = _maps(cell['subscribe_items']);
        if (items.isNotEmpty) subscription = items.first;
      }
      final episodes = <SearchSeriesEpisode>[];
      final episodeIndices = <int>[];
      if (subscription.isEmpty) {
        for (var docIndex = 0; docIndex < docs.length; docIndex++) {
          final doc = docs[docIndex];
          if (_number(doc['show_type']) != 659 ||
              _number(doc['search_ip_card_content_type']) != 22) {
            continue;
          }
          final data = _maps(doc['video_data']);
          if (data.isEmpty) continue;
          final episode = SearchSeriesEpisode.tryParse(data.first,
              title: _text(doc['cell_name']));
          if (episode == null) continue;
          episodes.add(episode);
          episodeIndices.add(docIndex);
        }
      }
      var title = _text(cell['cell_name']);
      if (title.trim().isEmpty) title = _text(video['title']);
      if (title.trim().isEmpty) title = _text(subscription['name']);
      if (title.trim().isEmpty) title = '第${index + 1}季';
      if (video.isEmpty && subscription.isEmpty && episodes.isEmpty) continue;
      final seriesId = _text(video['series_id']);
      final detail = _map(video['video_detail']);
      final drama = (int.tryParse(seriesId) ?? 0) > 0
          ? Drama.fromTheaterSearchJson({
              ...video,
              'video_detail': {
                ...detail,
                'series_id': seriesId,
                'series_intro': video['video_desc'] ?? detail['series_intro'],
              },
            })
          : null;
      indices.add(index);
      seasons.add(SearchSeriesSeason(
        id: _text(cell['cell_id_str']).trim().isNotEmpty
            ? _text(cell['cell_id_str'])
            : (_number(cell['cell_id']) ?? 0) != 0
                ? _text(cell['cell_id'])
                : seriesId.isNotEmpty
                    ? seriesId
                    : 'season_$index',
        sourceIndex: index,
        title: _highlight(cell, 'cell_name', title),
        seriesId: seriesId,
        drama: drama,
        cover: _text(video['cover'] ?? subscription['cover']),
        subtitle: _text(cell['cell_abstract'] ?? video['sub_title']),
        episodes: List.unmodifiable(episodes),
        initialEpisodeIndex:
            _selected(cell['search_ip_card_selected_idx'], episodeIndices),
        subscription: Map.unmodifiable(subscription),
        raw: Map.unmodifiable(cell),
      ));
    }
    if (seasons.isEmpty ||
        !seasons.any((season) => season.seriesId.isNotEmpty)) {
      return null;
    }
    var title = _text(raw['cell_name']);
    if (title.trim().isEmpty) {
      title = seasons
              .firstWhere((season) => season.drama != null,
                  orElse: () => seasons.first)
              .drama
              ?.name ??
          seasons.first.title;
    }
    if (title.trim().isEmpty) return null;
    return SearchSeriesV3Data(
      title: _highlight(raw, 'cell_name', title),
      subtitle: _text(raw['cell_abstract']),
      seasons: List.unmodifiable(seasons),
      initialSeasonIndex:
          _selected(raw['search_ip_card_selected_idx'], indices),
    );
  }
}

class SearchSeriesSeason {
  const SearchSeriesSeason({
    required this.id,
    required this.sourceIndex,
    required this.title,
    required this.seriesId,
    required this.drama,
    required this.cover,
    required this.subtitle,
    required this.episodes,
    required this.initialEpisodeIndex,
    required this.subscription,
    required this.raw,
  });

  final String id;
  final int sourceIndex;
  final String title;
  final String seriesId;
  final Drama? drama;
  final String cover;
  final String subtitle;
  final List<SearchSeriesEpisode> episodes;
  final int initialEpisodeIndex;
  final Map<String, dynamic> subscription;
  final Map<String, dynamic> raw;
  bool get isUpcoming => subscription.isNotEmpty;
  String get key => '$id:$sourceIndex';
  String get routeUrl => _text(subscription['schema']).trim().isNotEmpty
      ? _text(subscription['schema'])
      : _text(subscription['detail_schema']);
}

class SearchSeriesEpisode {
  const SearchSeriesEpisode({
    required this.vid,
    required this.seriesId,
    required this.number,
    required this.title,
    required this.raw,
  });

  final String vid;
  final String seriesId;
  final int number;
  final String title;
  final Map<String, dynamic> raw;

  static SearchSeriesEpisode? tryParse(Map<String, dynamic> raw,
      {String title = ''}) {
    final vid = _text(raw['vid']);
    final series = _text(raw['series_id']);
    final number = _number(raw['vid_index']) ?? 0;
    if (vid.trim().isEmpty || series.trim().isEmpty || number <= 0) return null;
    return SearchSeriesEpisode(
      vid: vid,
      seriesId: series,
      number: number,
      title: title.trim().isEmpty ? '$number' : title,
      raw: Map.unmodifiable(raw),
    );
  }
}
