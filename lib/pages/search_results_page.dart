import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../models/search_results.dart';
import '../models/search_source.dart';
import '../services/api_client.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../widgets/search_series_album_card.dart';
import '../widgets/search_series_card.dart';
import '../widgets/tv_tap.dart';
import 'player_page.dart';

class SearchResultsPage extends StatefulWidget {
  const SearchResultsPage({
    super.key,
    required this.keyword,
    required this.apiClient,
    this.useCorrect = false,
    this.downloadService,
    this.source = SearchSource.comic,
    this.clickedContent,
    this.searchSourceId,
    this.clientExtra,
  });
  final String keyword;
  final ApiClient apiClient;
  final bool useCorrect;
  final DownloadService? downloadService;
  final SearchSource source;
  final String? clickedContent;
  final String? searchSourceId;
  final String? clientExtra;

  @override
  State<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends State<SearchResultsPage> {
  static const _tvInitialResultCount = 24;
  static const _tvInitialPageLimit = 6;
  final _scrollController = ScrollController();
  final _backFocus = FocusNode();
  final Map<String, FocusNode> _scopeFocus = {};
  final Map<String, FocusNode> _resultFocus = {};
  final Set<String> _pageCursors = {};
  List<SearchResultGroup> _groups = const [];
  List<SearchScope> _scopes = const [];
  SearchResultTab? _cursor;
  late SearchQuery _query;
  CancelToken? _searchCancel;
  String? _scopeKey;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hadError = false;
  bool _moreError = false;
  bool _hasMore = false;
  int _generation = 0;
  int _initialPagesLoaded = 0;

  @override
  void initState() {
    super.initState();
    _query = SearchQuery(
      query: widget.keyword,
      useCorrect: widget.useCorrect,
      source: widget.source,
      clickedContent: widget.clickedContent,
      searchSourceId: widget.searchSourceId,
      clientExtra: widget.clientExtra,
    );
    _scrollController.addListener(_onScroll);
    unawaited(_fetch());
  }

  @override
  void dispose() {
    _searchCancel?.cancel();
    _scrollController.dispose();
    _backFocus.dispose();
    for (final node in [..._scopeFocus.values, ..._resultFocus.values]) {
      node.dispose();
    }
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter < 240 &&
        !_loading &&
        !_loadingMore &&
        !_moreError &&
        _hasMore) {
      unawaited(_fetchMore());
    }
  }

  SearchResultTab? _tabFor(SearchResultsResponse response, SearchQuery query) =>
      response.tabs.where((tab) => tab.type == query.tabType).firstOrNull ??
      response.primaryTab;

  // 一张满宽系列卡占一个纵向单元，不能用隐藏分组的季数凑满首屏。
  int get _displayResultCount => _groups.fold(
      0,
      (count, group) =>
          count +
          group.entries.length +
          group.seriesAlbums.length +
          group.seriesCards.length);

  void _scheduleTvPrefetch() {
    if (!DeviceProfile.isTv) return;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _generation ||
          _loading ||
          _loadingMore ||
          _hadError ||
          _moreError ||
          !_hasMore ||
          _initialPagesLoaded >= _tvInitialPageLimit ||
          _displayResultCount >= _tvInitialResultCount) {
        return;
      }
      unawaited(_fetchMore());
    });
  }

  Future<void> _fetch({SearchScope? scope}) async {
    final generation = ++_generation;
    _searchCancel?.cancel();
    final cancel = _searchCancel = CancelToken();
    if (scope != null) _query = _query.forScope(scope);
    _pageCursors.clear();
    _initialPagesLoaded = 0;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hadError = false;
      _moreError = false;
      _groups = const [];
      _scopeKey = scope?.key ?? _scopeKey;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    try {
      final response =
          await widget.apiClient.searchResults(_query, cancelToken: cancel);
      if (!mounted || generation != _generation) return;
      final tab = _tabFor(response, _query);
      setState(() {
        _cursor = tab;
        _initialPagesLoaded = 1;
        _groups = tab?.groups ?? const [];
        _hasMore = tab?.hasMore ?? false;
        // 筛选响应的默认选项不代表用户当前选择，不据此重置快捷标签。
        if (scope == null && tab != null) {
          _scopes = response.scopes;
          _scopeKey = _scopes
                  .where((scope) =>
                      scope.source == _query.source &&
                      scope.tabType == tab.type &&
                      scope.selectedItems.isEmpty)
                  .firstOrNull
                  ?.key ??
              _scopes.firstOrNull?.key;
        }
        _loading = false;
      });
      _scheduleTvPrefetch();
    } catch (error) {
      if (!mounted || generation != _generation || cancel.isCancelled) return;
      setState(() {
        _loading = false;
        _hadError = true;
      });
    }
  }

  Future<void> _fetchMore() async {
    final cursor = _cursor;
    if (_loading || _loadingMore || !_hasMore || cursor == null) return;
    final query = _query.nextPage(cursor);
    if (_pageCursors.contains(query.cursorKey)) {
      setState(() => _hasMore = false);
      return;
    }
    final generation = _generation;
    final cancel = _searchCancel = CancelToken();
    setState(() {
      _loadingMore = true;
      _moreError = false;
    });
    try {
      final response =
          await widget.apiClient.searchResults(query, cancelToken: cancel);
      if (!mounted || generation != _generation) return;
      final tab = _tabFor(response, query);
      if (tab == null) throw ApiException('搜索分页返回格式错误');
      setState(() {
        _initialPagesLoaded++;
        _pageCursors.add(query.cursorKey);
        _groups = [..._groups, ...tab.groups];
        _cursor = tab;
        _hasMore = tab.hasMore &&
            !_pageCursors.contains(_query.nextPage(tab).cursorKey);
        _loadingMore = false;
      });
      _scheduleTvPrefetch();
    } catch (error) {
      if (!mounted || generation != _generation || cancel.isCancelled) return;
      setState(() {
        _loadingMore = false;
        _moreError = true;
      });
    }
  }

  void _openDrama(Drama drama) => _openEpisode(drama);

  void _openEpisode(Drama drama, [int? episodeNumber]) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        drama: drama,
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
        initialEpisodeIndex: 0,
        initialEpisodeNumber: episodeNumber,
      ),
    ));
  }

  FocusNode _resultNode(String key) =>
      _resultFocus.putIfAbsent(key, () => FocusNode());

  FocusNode _scopeNode(SearchScope scope) =>
      _scopeFocus.putIfAbsent(scope.key, () {
        final node = FocusNode();
        node.onKeyEvent = (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final index = _scopes.indexWhere((item) => item.key == scope.key);
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight) {
            final next =
                index + (key == LogicalKeyboardKey.arrowRight ? 1 : -1);
            if (next >= 0 && next < _scopes.length) {
              _scopeNode(_scopes[next]).requestFocus();
            }
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp) {
            _backFocus.requestFocus();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowDown) {
            final first = _firstResultKey;
            if (first != null && !_loading) {
              _resultNode(first).requestFocus();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        };
        return node;
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFFF5F5F7),
        body: SafeArea(
          child: FocusTraversalGroup(
            child: CustomScrollView(
              key: const ValueKey('search-results-scroll'),
              controller: _scrollController,
              slivers: [
                SliverAppBar(
                  backgroundColor: const Color(0xFFF5F5F7),
                  surfaceTintColor: Colors.transparent,
                  pinned: true,
                  centerTitle: true,
                  leading: Padding(
                    padding: const EdgeInsets.all(6),
                    child: TvTap(
                      focusNode: _backFocus,
                      onTap: () => Navigator.of(context).pop(),
                      child: const Center(
                          child:
                              Icon(Icons.arrow_back_ios_new_rounded, size: 20)),
                    ),
                  ),
                  title: Text(widget.keyword,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600)),
                ),
                if (_scopes.isNotEmpty)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _SearchScopeHeader(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(children: [
                          for (final scope in _scopes)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: TvTap(
                                key: ValueKey('search-scope-${scope.key}'),
                                focusNode: _scopeNode(scope),
                                autofocus: scope == _scopes.first,
                                borderRadius: 18,
                                focusScale: 1,
                                onTap: () {
                                  if (_scopeKey != scope.key || _hadError) {
                                    unawaited(_fetch(scope: scope));
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 22, vertical: 9),
                                  decoration: BoxDecoration(
                                    color: _scopeKey == scope.key
                                        ? const Color(0xFF1D1D1F)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Text(scope.title,
                                      style: TextStyle(
                                          color: _scopeKey == scope.key
                                              ? Colors.white
                                              : const Color(0xFF65656B),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ),
                        ]),
                      ),
                    ),
                  ),
                if (_loading)
                  const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator()))
                else if (!_hasDisplayResults)
                  if (_hasMore)
                    const SliverToBoxAdapter(
                        child: Padding(
                            padding: EdgeInsets.all(48),
                            child: Center(child: Text('当前页暂无可播放剧集，可继续加载'))))
                  else
                    SliverFillRemaining(hasScrollBody: false, child: _empty())
                else
                  ..._resultSlivers(),
                if (!_loading && (_hasMore || _hasDisplayResults))
                  SliverToBoxAdapter(
                      child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    child: Center(
                        child: _loadingMore
                            ? const CircularProgressIndicator(strokeWidth: 2)
                            : _hasMore
                                ? TvTap(
                                    key: const ValueKey('search-load-more'),
                                    onTap: _fetchMore,
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Text(
                                            _moreError ? '加载失败，点击重试' : '加载更多')),
                                  )
                                : const Text('已显示全部结果',
                                    style: TextStyle(
                                        color: Color(0xFF8B8B93),
                                        fontSize: 12))),
                  )),
              ],
            ),
          ),
        ),
      );

  Widget _empty() => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(_hadError ? Icons.wifi_off_rounded : Icons.search_off_rounded,
            size: 54, color: Colors.grey[400]),
        const SizedBox(height: 16),
        Text(_hadError ? '搜索失败，请稍后重试' : '未找到相关内容'),
        if (_hadError)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TvTap(
                onTap: () => _fetch(
                    scope: _scopes
                        .where((scope) => scope.key == _scopeKey)
                        .firstOrNull),
                child: const Padding(
                    padding: EdgeInsets.all(16), child: Text('重试'))),
          ),
      ]));

  bool get _hasDisplayResults => _groups.any((group) =>
      group.entries.isNotEmpty ||
      group.seriesAlbums.isNotEmpty ||
      group.seriesCards.isNotEmpty);

  String _entryKey(int group, int entry) => 'group-$group-entry-$entry';
  String _seriesKey(int group, int entry) => 'group-$group-series-$entry';
  String _seriesCardKey(int group, int entry) =>
      'group-$group-series-card-$entry';

  String? get _firstResultKey {
    for (var group = 0; group < _groups.length; group++) {
      if (_groups[group].entries.isNotEmpty) return _entryKey(group, 0);
      if (_groups[group].seriesAlbums.isNotEmpty) return _seriesKey(group, 0);
      if (_groups[group].seriesCards.isNotEmpty) {
        return _seriesCardKey(group, 0);
      }
    }
    return null;
  }

  List<Widget> _resultSlivers() {
    final slivers = <Widget>[];
    final regular = <({Drama drama, String key})>[];
    void flush() {
      if (regular.isEmpty) return;
      final items = List<({Drama drama, String key})>.of(regular);
      regular.clear();
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        sliver: SliverGrid(
          gridDelegate: DeviceProfile.usesFocusUi
              ? const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 190,
                  childAspectRatio: .53,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 18)
              : const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: .53,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 18),
          delegate: SliverChildBuilderDelegate(
              (_, index) => _gridItem(items[index].drama, items[index].key),
              childCount: items.length),
        ),
      ));
    }

    // 结果归属、顺序由原搜索卡决定，不能用额外目录或跨卡作品ID重组。
    for (var groupIndex = 0; groupIndex < _groups.length; groupIndex++) {
      final group = _groups[groupIndex];
      for (var index = 0; index < group.entries.length; index++) {
        regular.add(
            (drama: group.entries[index], key: _entryKey(groupIndex, index)));
      }
      if (group.seriesCards.isNotEmpty) {
        flush();
        for (var index = 0; index < group.seriesCards.length; index++) {
          final resultKey = _seriesCardKey(groupIndex, index);
          slivers.add(SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(DeviceProfile.isTv ? 16 : 12, 12,
                  DeviceProfile.isTv ? 16 : 12, 8),
              child: SearchSeriesCard(
                key: ValueKey(resultKey),
                data: group.seriesCards[index],
                focusNode: _resultNode(resultKey),
                onPlay: _openDrama,
                onPlayEpisode: (drama, number) => _openEpisode(drama, number),
                onLoadSeason: (season) => widget.apiClient.fetchSearchSeason(
                  season.seriesId,
                  source: _query.source,
                  cancelToken: _searchCancel,
                ),
                onOpenBook: (_) => ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('当前仅支持视频播放'))),
              ),
            ),
          ));
        }
      }
      if (group.seriesAlbums.isEmpty) continue;
      flush();
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (group.seriesAlbums.first.moduleTitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(group.seriesAlbums.first.moduleTitle,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(4),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var index = 0; index < group.seriesAlbums.length; index++)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: SearchSeriesAlbumCard(
                      key: ValueKey(_seriesKey(groupIndex, index)),
                      album: group.seriesAlbums[index],
                      focusNode: _resultNode(_seriesKey(groupIndex, index)),
                      onPlay: _openDrama,
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ));
    }
    flush();
    return slivers;
  }

  Widget _gridItem(Drama drama, String resultKey) => TvTap(
        key: ValueKey('search-drama-$resultKey-${drama.id}'),
        focusNode: _resultNode(resultKey),
        borderRadius: 10,
        onTap: () => _openDrama(drama),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(aspectRatio: 1 / 1.4, child: _cover(drama)),
          const SizedBox(height: 8),
          Text(drama.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, height: 1.4)),
          if (drama.recText?.isNotEmpty == true)
            Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(drama.recText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF96969D)))),
        ]),
      );

  Widget _cover(Drama drama) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
            color: const Color(0xFFE8E8ED),
            child: drama.cover.isEmpty
                ? const Center(
                    child: Icon(Icons.movie_outlined, color: Color(0xFFB7B7BF)))
                : Image.network(drama.cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Center(
                        child: Icon(Icons.movie_outlined,
                            color: Color(0xFFB7B7BF))))),
      );
}

class _SearchScopeHeader extends SliverPersistentHeaderDelegate {
  _SearchScopeHeader({required this.child});
  final Widget child;
  @override
  double get minExtent => 64;
  @override
  double get maxExtent => 64;
  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox.expand(
          child: ColoredBox(color: const Color(0xFFF5F5F7), child: child));
  @override
  bool shouldRebuild(_SearchScopeHeader oldDelegate) =>
      oldDelegate.child != child;
}
