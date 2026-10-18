import 'dart:convert';

import 'drama.dart';
import 'search_series_card.dart';
import 'search_source.dart';

/// 搜索范围和分页属于同一会话，游标必须使用上游返回值。
class SearchQuery {
  const SearchQuery({
    required this.query,
    this.tabType,
    this.selectedItems,
    this.offset = 0,
    this.passback,
    this.searchId,
    this.correctedQuery,
    this.useCorrect = false,
    this.firstEnter = true,
    this.source = SearchSource.comic,
    this.clickedContent,
    this.searchSourceId,
    this.clientExtra,
  });

  final String query;
  final int? tabType;
  final String? selectedItems;
  final int offset;
  final String? passback;
  final String? searchId;
  final String? correctedQuery;
  final bool useCorrect;
  final bool firstEnter;
  final SearchSource source;
  final String? clickedContent;
  final String? searchSourceId;
  final String? clientExtra;

  Map<String, dynamic> toQueryParameters() => {
        'query': query,
        'source': source.value,
        if (clickedContent != null) 'clicked_content': clickedContent,
        if (searchSourceId != null) 'search_source_id': searchSourceId,
        if (clientExtra != null) 'client_extra': clientExtra,
        if (tabType != null) 'tab_type': tabType,
        if (selectedItems != null) 'selected_items': selectedItems,
        'offset': offset,
        if (passback != null) 'passback': passback,
        if (searchId != null) 'search_id': searchId,
        if (correctedQuery != null) 'corrected_query': correctedQuery,
        'use_correct': useCorrect.toString(),
        'is_first_enter_search': firstEnter.toString(),
      };

  SearchQuery forScope(SearchScope scope) => SearchQuery(
        query: query,
        tabType: scope.tabType,
        selectedItems: scope.selectedItems,
        useCorrect: useCorrect,
        source: scope.source,
        clickedContent: scope.source == source ? clickedContent : null,
        searchSourceId: scope.source == source ? searchSourceId : null,
        // 原应用切 tab 后保留来源标识，但不重发联想的落点上下文。
        clientExtra: null,
        firstEnter: scope.source != source,
      );

  SearchQuery nextPage(SearchResultTab tab) => SearchQuery(
        query: query,
        tabType: tab.type,
        selectedItems: selectedItems,
        offset: tab.nextOffset,
        passback: tab.passback,
        searchId: tab.searchId,
        correctedQuery: tab.correctedQuery,
        useCorrect: useCorrect,
        firstEnter: false,
        source: source,
        clickedContent: clickedContent,
        searchSourceId: searchSourceId,
        clientExtra: clientExtra,
      );

  String get cursorKey =>
      jsonEncode([source.value, tabType, offset, passback, searchId]);
}

/// 快捷标签使用上游真实内容筛选项，并非伪造三个 search_tabs。
class SearchScope {
  const SearchScope(this.title, this.tabType,
      {this.selectedItems = '', this.source = SearchSource.comic});
  final String title;
  final int tabType;
  final String selectedItems;
  final SearchSource source;
  String get key => '${source.value}:$tabType:$selectedItems';
}

class SearchResultsResponse {
  const SearchResultsResponse({
    required this.tabs,
    this.selectedTabIndex = 0,
    this.source = SearchSource.comic,
  });
  final List<SearchResultTab> tabs;
  final int selectedTabIndex;
  final SearchSource source;

  List<SearchScope> get scopes {
    final videoTabs = tabs.where((tab) => tab.supportsVideo).toList();
    final result = videoTabs.length > 1
        ? [
            for (final tab in videoTabs)
              SearchScope(tab.title, tab.type, source: source)
          ]
        : [...?videoTabs.firstOrNull?.scopes];
    if (source == SearchSource.comic && videoTabs.isNotEmpty) {
      result.add(const SearchScope('真人剧', 11,
          source: SearchSource.shortplay,
          selectedItems: 'content_type_short_play'));
    }
    return result;
  }

  SearchResultTab? get primaryTab {
    if (tabs.isEmpty) return null;
    final selected = tabs[selectedTabIndex.clamp(0, tabs.length - 1)];
    if (selected.supportsVideo) return selected;
    return tabs.where((tab) => tab.supportsVideo).firstOrNull;
  }

  factory SearchResultsResponse.fromJson(Map<String, dynamic> json,
          {SearchSource source = SearchSource.comic}) =>
      SearchResultsResponse(
        source: source,
        tabs: [
          if (json['search_tabs'] is List)
            for (final tab in json['search_tabs'] as List)
              if (tab is Map)
                SearchResultTab.fromJson(tab.cast<String, dynamic>(),
                    source: source),
        ],
        selectedTabIndex: _integer(json['selected_tab_idx']),
      );
}

class SearchResultTab {
  const SearchResultTab({
    required this.type,
    required this.title,
    required this.groups,
    this.scopes = const [],
    this.hasMore = false,
    this.nextOffset = 0,
    this.passback = '',
    this.searchId = '',
    this.correctedQuery = '',
  });

  final int type;
  final String title;
  final List<SearchResultGroup> groups;
  final List<SearchScope> scopes;
  final bool hasMore;
  final int nextOffset;
  final String passback;
  final String searchId;
  final String correctedQuery;
  bool get supportsVideo => const {11, 12, 14, 19, 32, 33}.contains(type);

  factory SearchResultTab.fromJson(Map<String, dynamic> json,
      {SearchSource source = SearchSource.comic}) {
    final type = _integer(json['tab_type']);
    final title = json['title']?.toString() ?? '综合';
    final contentItems = <String>{};
    final selector = json['selector'];
    final rows = selector is Map ? selector['rows'] : null;
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map || row['type'] != 'content_type') continue;
        final items = row['items'];
        if (items is! List) continue;
        for (final item in items) {
          if (item is Map && item['selector_item_id'] is String) {
            contentItems.add(item['selector_item_id'] as String);
          }
        }
      }
    }
    return SearchResultTab(
      type: type,
      title: title,
      groups: [
        if (json['data'] is List)
          for (final cell in json['data'] as List)
            if (cell is Map)
              SearchResultGroup.fromJson(cell.cast<String, dynamic>()),
      ],
      scopes: [
        SearchScope(title, type, source: source),
        if (contentItems.contains('content_type_dynamic_comic'))
          SearchScope('漫剧', type,
              selectedItems: 'content_type_dynamic_comic', source: source),
        if (contentItems.contains('content_type_short_play'))
          SearchScope('短剧', type,
              selectedItems: 'content_type_short_play', source: source),
      ],
      hasMore: json['has_more'] == true || json['has_more'] == 1,
      nextOffset: _integer(json['next_offset']),
      passback: json['passback']?.toString() ?? '',
      searchId: json['search_id']?.toString() ?? '',
      correctedQuery: json['corrected_query']?.toString() ?? '',
    );
  }
}

/// 正式搜索保留服务器卡片边界，只在已核实类型中解析可展示内容。
class SearchResultGroup {
  const SearchResultGroup({
    required this.entries,
    this.title = '',
    this.showType = 0,
    this.seriesAlbums = const [],
    this.seriesCards = const [],
    this.raw = const {},
    this.renderType = 0,
  });

  final List<Drama> entries;
  final String title;
  final int showType;
  final List<SearchSeriesAlbum> seriesAlbums;
  final List<SearchSeriesCardData> seriesCards;
  final Map<String, dynamic> raw;
  final int renderType;

  factory SearchResultGroup.fromJson(Map<String, dynamic> json) {
    final type = _integer(json['show_type']);
    final renderType = _integer(json['render_cell_type']);
    final entries = <Drama>[];
    final albums = <SearchSeriesAlbum>[];
    final cards = <SearchSeriesCardData>[];
    if (renderType != 1) {
      final card = SearchSeriesCardData.tryParse(json);
      if (card != null) cards.add(card);
      // l0.Z 等普通卡路径只取首个视频，不能把附属内容提升成搜索结果。
      if (const {369, 412, 420, 476}.contains(type)) {
        final video = _firstMap(json['video_data']);
        final drama = video == null ? null : _searchDrama(video);
        if (drama != null) entries.add(drama);
      } else if (type == 551) {
        final album = SearchSeriesAlbum.fromCell(json);
        if (album != null) albums.add(album);
      } else if (type == 549 || type == 601) {
        // vi4.h：IP 根卡 -> 550 模块 -> 551 关联项。保留模块，禁止通用递归。
        for (final module in _mapList(json['cell_data'])) {
          if (_integer(module['show_type']) != 550 ||
              _integer(module['render_cell_type']) == 1) {
            continue;
          }
          for (final cell in _mapList(module['cell_data'])) {
            final album = SearchSeriesAlbum.fromCell(
              cell,
              moduleTitle: _text(module['cell_name']),
            );
            if (album != null) albums.add(album);
          }
        }
      }
    }
    // 未还原模板、612同IP、572图文均保留原始字段，不能冒充普通剧或季。
    return SearchResultGroup(
      entries: List.unmodifiable(entries),
      title: _text(json['cell_name']),
      showType: type,
      seriesAlbums: List.unmodifiable(albums),
      seriesCards: List.unmodifiable(cards),
      raw: Map.unmodifiable(json),
      renderType: renderType,
    );
  }
}

class SearchSeriesAlbum {
  const SearchSeriesAlbum({
    required this.preview,
    required this.moduleTitle,
    required this.items,
  });

  final Drama preview;
  final String moduleTitle;
  final List<SearchSeriesItem> items;

  /// sf4.a（raw交叉）：仅551+SeriesAlbum(24)有效，数据全部来自当前响应。
  static SearchSeriesAlbum? fromCell(
    Map<String, dynamic> cell, {
    String moduleTitle = '',
  }) {
    if (_integer(cell['show_type']) != 551 ||
        _integer(cell['search_ip_card_content_type']) != 24 ||
        _integer(cell['render_cell_type']) == 1) {
      return null;
    }
    final video = _firstMap(cell['video_data']);
    if (video == null || _seriesId(video['series_id']) == null) return null;
    final albumInfo = _map(video['album_info']);
    final title = _fallbackText(video['title'], [albumInfo?['title']]);
    final cover = _fallbackText(
      video['cover'],
      [albumInfo?['small_cover'], albumInfo?['cover']],
    );
    final preview = _searchDrama(
      video,
      requireTopLevelId: true,
      title: title,
      cover: cover,
      episodeCount: albumInfo == null
          ? _integer(video['episode_cnt'])
          : _integer(albumInfo['episode_total_cnt']),
    );
    if (preview == null) return null;
    final items = <SearchSeriesItem>[];
    final seen = <String>{};
    for (final itemCell in _mapList(cell['cell_data'])) {
      final item = SearchSeriesItem.fromCell(itemCell);
      if (item != null && seen.add(item.key)) items.add(item);
    }
    if (items.isEmpty) return null;
    return SearchSeriesAlbum(
      preview: preview,
      moduleTitle: moduleTitle,
      items: List.unmodifiable(items),
    );
  }
}

class SearchSeriesItem {
  const SearchSeriesItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.routeUrl,
    required this.isPlayable,
    this.drama,
  });

  final String id;
  final String title;
  final String cover;
  final String routeUrl;
  final bool isPlayable;
  final Drama? drama;

  String get key => '${isPlayable ? 'playable' : 'reservable'}:$id';

  static SearchSeriesItem? fromCell(Map<String, dynamic> cell) {
    final video = _firstMap(cell['video_data']);
    final playableId = _seriesId(video?['series_id']);
    final subscription = _firstMap(cell['subscribe_items']);
    final reservationId = _reservationId(subscription);
    // raw L209：同一条目同时带有效可播ID和预约ID时丢弃，不擅自挑一种。
    if (playableId != null && reservationId != null) return null;
    if (video != null && playableId != null) {
      final title = _fallbackText(video['title'], [cell['cell_name']]);
      final cover = _fallbackText(video['cover'], [cell['cell_picture_url']]);
      final drama = _searchDrama(
        video,
        requireTopLevelId: true,
        title: title,
        cover: cover,
      );
      if (drama == null) return null;
      return SearchSeriesItem(
        id: playableId,
        title: title,
        cover: cover,
        routeUrl: _text(video['url']),
        isPlayable: true,
        drama: drama,
      );
    }
    if (subscription == null || reservationId == null) return null;
    return SearchSeriesItem(
      id: reservationId,
      title: _fallbackText(subscription['name'], [cell['cell_name']]),
      cover: _fallbackText(subscription['cover'], [cell['cell_picture_url']]),
      routeUrl: _fallbackText(
        subscription['schema'],
        [subscription['detail_schema'], cell['cell_url']],
      ),
      isPlayable: false,
    );
  }
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;

Map<String, dynamic>? _firstMap(Object? value) =>
    value is List && value.isNotEmpty ? _map(value.first) : null;

Iterable<Map<String, dynamic>> _mapList(Object? value) sync* {
  if (value is! List) return;
  for (final item in value) {
    final map = _map(item);
    if (map != null) yield map;
  }
}

String _text(Object? value) => value is String ? value : '';

String _fallbackText(Object? value, List<Object?> fallbacks) {
  var result = _text(value);
  for (final fallback in fallbacks) {
    if (result.isNotEmpty) break;
    result = _text(fallback);
  }
  return result;
}

String? _seriesId(Object? value) {
  final text = value is String || value is int ? value.toString() : '';
  return (int.tryParse(text) ?? 0) > 0 ? text : null;
}

String? _reservationId(Map<String, dynamic>? subscription) {
  if (subscription == null) return null;
  final text = _text(subscription['item_id_str']);
  if (text.trim().isNotEmpty) return text;
  return _seriesId(subscription['item_id']);
}

Drama? _searchDrama(
  Map<String, dynamic> video, {
  bool requireTopLevelId = false,
  String? title,
  String? cover,
  int? episodeCount,
}) {
  final detail = _map(video['video_detail']);
  final id = _seriesId(requireTopLevelId
      ? video['series_id']
      : detail?['series_id_str'] ?? detail?['series_id'] ?? video['series_id']);
  if (id == null) return null;
  return Drama.fromTheaterSearchJson({
    ...video,
    if (title != null) 'title': title,
    if (cover != null) 'cover': cover,
    if (episodeCount != null)
      'episode_cnt': episodeCount < 0 ? 0 : episodeCount,
    'video_detail': {
      if (detail != null) ...detail,
      'series_id': int.parse(id),
    },
  });
}

int _integer(Object? value) =>
    value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;
