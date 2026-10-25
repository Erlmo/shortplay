import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../models/search_series_card.dart';
import '../services/device_profile.dart';
import 'tv_tap.dart';

part 'search_series_v3_card.dart'; // V3 样式系列卡与横滑轨道

double _seriesSize(double value) => value * (DeviceProfile.isTv ? 4 / 3 : 1);

/// 红果漫剧的卡片调色板与 host 选中色，不使用 Material 的品牌色派生背景。
class _SeriesPalette {
  _SeriesPalette(BuildContext context)
      : dark = Theme.of(context).brightness == Brightness.dark;

  final bool dark;
  Color get background => dark ? const Color(0xFF1C1C1C) : Colors.white;
  Color get title => dark ? Colors.white : const Color(0xFF1B1B1B);
  Color get subtitle =>
      dark ? const Color(0x66FFFFFF) : const Color(0x66000000);
  Color get tabBackground =>
      dark ? const Color(0x0FFFFFFF) : const Color(0x08000000);
  Color get tabText => dark ? const Color(0x99FFFFFF) : const Color(0xB2000000);
  Color get selectedBackground =>
      dark ? const Color(0x2661F2D0) : const Color(0x4061F2D0);
  Color get selectedText => const Color(0xFF00B893);
  Color get placeholder =>
      dark ? const Color(0xFF303030) : const Color(0xFFF1F1F1);
  Color get heroBackground =>
      dark ? const Color(0xFF222222) : const Color(0xFFFAFAFA);
  Color get chipText => dark ? const Color(0xCCFFFFFF) : Colors.black;
}

/// 655 的模块封面横排，或 656 的标题、副标题和单个封面横排。
class SearchSeriesCard extends StatefulWidget {
  const SearchSeriesCard({
    super.key,
    required this.data,
    required this.onPlay,
    this.onOpenBook,
    this.onOpenLink,
    this.focusNode,
    this.onLoadSeason,
    this.onPlayEpisode,
  });

  final SearchSeriesCardData data;
  final ValueChanged<Drama> onPlay;
  final ValueChanged<String>? onOpenBook;
  final ValueChanged<String>? onOpenLink;
  final FocusNode? focusNode;
  final Future<List<SearchSeriesEpisode>> Function(SearchSeriesSeason)?
      onLoadSeason;
  final void Function(Drama, int episodeNumber)? onPlayEpisode;

  @override
  State<SearchSeriesCard> createState() => _SearchSeriesCardState();
}

class _SearchSeriesCardState extends State<SearchSeriesCard> {
  late int _group;
  final List<FocusNode> _tabs = [];
  final List<List<FocusNode>> _items = [];
  final List<List<GlobalKey>> _keys = [];
  final List<ScrollController> _scrolls = [];
  final List<bool> _anchored = [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  void _initialize() {
    _group = widget.data.initialGroupIndex;
    if (widget.data.v3 != null) return;
    for (var group = 0; group < widget.data.groups.length; group++) {
      _tabs.add(FocusNode(debugLabel: 'series-group-$group'));
      _scrolls.add(ScrollController());
      _anchored.add(false);
      _items.add([
        for (var item = 0;
            item < widget.data.groups[group].items.length;
            item++)
          FocusNode(debugLabel: 'series-item-$group-$item'),
      ]);
      _keys.add([
        for (final _ in widget.data.groups[group].items) GlobalKey(),
      ]);
    }
    _showAnchor();
  }

  void _release() {
    for (final node in _tabs) {
      node.dispose();
    }
    for (final nodes in _items) {
      for (final node in nodes) {
        node.dispose();
      }
    }
    for (final scroll in _scrolls) {
      scroll.dispose();
    }
    _tabs.clear();
    _items.clear();
    _keys.clear();
    _scrolls.clear();
    _anchored.clear();
  }

  @override
  void didUpdateWidget(covariant SearchSeriesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _release();
      _initialize();
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  FocusNode _itemNode(int group, int item) => group == _group &&
          item == widget.data.groups[group].initialItemIndex &&
          widget.focusNode != null
      ? widget.focusNode!
      : _items[group][item];

  void _showAnchor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_anchored[_group]) return;
      final scroll = _scrolls[_group];
      if (!scroll.hasClients) return;
      final index = widget.data.groups[_group].initialItemIndex;
      final width = _seriesSize(84);
      scroll.jumpTo((index * (width + _seriesSize(8)))
          .clamp(0.0, scroll.position.maxScrollExtent));
      _anchored[_group] = true;
    });
  }

  KeyEventResult _navigate(KeyEvent event, int index, {required bool tabs}) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final count = tabs ? _tabs.length : _items[_group].length;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final next = index + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      if (next >= 0 && next < count) {
        (tabs ? _tabs[next] : _itemNode(_group, next)).requestFocus();
      }
      // 横排边界停留在本条目，上下和返回仍交还页面。
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _open(SearchSeriesCardItem item) {
    switch (item.kind) {
      case SearchSeriesItemKind.video:
        final drama = item.drama;
        if (drama != null) widget.onPlay(drama);
      case SearchSeriesItemKind.book:
        widget.onOpenBook?.call(item.id);
      case SearchSeriesItemKind.upcoming:
        // 不把预约条目的 item_id 当成可播放 series_id。
        if (item.routeUrl.isNotEmpty && widget.onOpenLink != null) {
          widget.onOpenLink!(item.routeUrl);
        } else {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('即将上线，敬请期待')));
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final v3 = widget.data.v3;
    if (v3 != null) {
      return _SearchSeriesV3Card(
        data: v3,
        onPlay: widget.onPlay,
        onPlayEpisode: widget.onPlayEpisode,
        onLoadSeason: widget.onLoadSeason,
        onOpenLink: widget.onOpenLink,
        focusNode: widget.focusNode,
      );
    }
    final palette = _SeriesPalette(context);
    final width = _seriesSize(84);
    final group = widget.data.groups[_group];
    return Container(
      key: const ValueKey('search-series-surface'),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(_seriesSize(12)),
      ),
      padding: EdgeInsets.only(
          top: _seriesSize(widget.data.showType == 656 ? 13 : 16),
          bottom: _seriesSize(16)),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: _seriesSize(16)),
              child: widget.data.showType == 656
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.data.title.isNotEmpty)
                          Text(widget.data.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: _seriesSize(16),
                                  height: 22 / 16,
                                  fontWeight: FontWeight.w500,
                                  color: palette.selectedText)),
                        if (widget.data.subtitle.isNotEmpty) ...[
                          if (widget.data.title.isNotEmpty)
                            SizedBox(height: _seriesSize(2)),
                          Text(widget.data.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: palette.subtitle,
                                  fontSize: _seriesSize(12),
                                  height: 17 / 12)),
                        ],
                      ],
                    )
                  : SizedBox(
                      height: _seriesSize(32),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(widget.data.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _seriesSize(18),
                              fontWeight: FontWeight.w500,
                              color: palette.selectedText,
                            )),
                      ),
                    ),
            ),
            if (widget.data.showType != 656 && widget.data.subtitle.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(
                    _seriesSize(16), _seriesSize(4), _seriesSize(16), 0),
                child: Text(widget.data.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: palette.subtitle,
                        fontSize: _seriesSize(12),
                        height: 17 / 12)),
              ),
            if (widget.data.groups.length > 1) ...[
              SizedBox(height: _seriesSize(4)),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: _seriesSize(16)),
                child: Row(children: [
                  for (var index = 0;
                      index < widget.data.groups.length;
                      index++)
                    Padding(
                      padding: EdgeInsets.only(right: _seriesSize(8)),
                      child: Focus(
                        canRequestFocus: false,
                        onKeyEvent: (_, event) =>
                            _navigate(event, index, tabs: true),
                        child: TvTap(
                          key: ValueKey('search-series-group-$index'),
                          focusNode: _tabs[index],
                          behavior: HitTestBehavior.opaque,
                          borderRadius: _seriesSize(6),
                          focusScale: 1,
                          onTap: () {
                            setState(() => _group = index);
                            _showAnchor();
                          },
                          child: Container(
                            width: _seriesSize(64),
                            height: _seriesSize(28),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: index == _group
                                  ? palette.selectedBackground
                                  : palette.tabBackground,
                              borderRadius:
                                  BorderRadius.circular(_seriesSize(6)),
                            ),
                            child: Text(widget.data.groups[index].title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: _seriesSize(12),
                                    fontWeight: FontWeight.w500,
                                    color: index == _group
                                        ? palette.selectedText
                                        : palette.tabText)),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ],
            SizedBox(height: _seriesSize(12)),
            SingleChildScrollView(
              key: ValueKey('search-series-scroll-$_group'),
              controller: _scrolls[_group],
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: _seriesSize(16)),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var index = 0; index < group.items.length; index++)
                  Padding(
                    key: _keys[_group][index],
                    padding: EdgeInsets.only(
                        right: index + 1 == group.items.length
                            ? 0
                            : _seriesSize(8)),
                    child: Focus(
                      canRequestFocus: false,
                      onKeyEvent: (_, event) =>
                          _navigate(event, index, tabs: false),
                      child: TvTap(
                        key: ValueKey('search-series-item-$_group-$index'),
                        focusNode: _itemNode(_group, index),
                        behavior: HitTestBehavior.opaque,
                        focusScale: 1,
                        onTap: () => _open(group.items[index]),
                        borderRadius: _seriesSize(12),
                        child: SizedBox(
                          width: width,
                          child: _SeriesCover(
                              item: group.items[index], width: width),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ]),
    );
  }
}

class _SeriesCover extends StatelessWidget {
  const _SeriesCover({required this.item, required this.width});

  final SearchSeriesCardItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = _SeriesPalette(context);
    final placeholder = ColoredBox(
      color: palette.placeholder,
      child: Center(
          child: Icon(Icons.movie_outlined,
              size: _seriesSize(24), color: palette.subtitle)),
    );
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(_seriesSize(12)),
            child: SizedBox(
              key: ValueKey('search-series-cover-${item.key}'),
              width: width,
              height: width * 119 / 84,
              child: item.cover.isEmpty
                  ? placeholder
                  : Image.network(item.cover,
                      fit: BoxFit.cover,
                      frameBuilder: (_, child, frame, synchronous) =>
                          synchronous || frame != null ? child : placeholder,
                      errorBuilder: (_, __, ___) => placeholder),
            ),
          ),
          SizedBox(height: _seriesSize(8)),
          Text(item.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: palette.title,
                  fontWeight: FontWeight.w500,
                  fontSize: _seriesSize(14),
                  height: 20 / 14)),
          SizedBox(height: _seriesSize(4)),
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: _seriesSize(17)),
            child: Text(
                item.subtitle.isNotEmpty
                    ? item.subtitle
                    : item.kind == SearchSeriesItemKind.upcoming
                        ? '待上线'
                        : '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: palette.subtitle,
                    fontSize: _seriesSize(12),
                    height: 17 / 12)),
          ),
        ]);
  }
}
