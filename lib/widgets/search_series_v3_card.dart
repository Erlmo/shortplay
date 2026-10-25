part of 'search_series_card.dart';

class _SearchSeriesV3Card extends StatefulWidget {
  const _SearchSeriesV3Card({
    required this.data,
    required this.onPlay,
    this.onPlayEpisode,
    this.onLoadSeason,
    this.onOpenLink,
    this.focusNode,
  });

  final SearchSeriesV3Data data;
  final ValueChanged<Drama> onPlay;
  final void Function(Drama, int)? onPlayEpisode;
  final Future<List<SearchSeriesEpisode>> Function(SearchSeriesSeason)?
      onLoadSeason;
  final ValueChanged<String>? onOpenLink;
  final FocusNode? focusNode;

  @override
  State<_SearchSeriesV3Card> createState() => _SearchSeriesV3CardState();
}

class _SearchSeriesV3CardState extends State<_SearchSeriesV3Card> {
  late int _selected;
  final Map<String, List<SearchSeriesEpisode>> _cache = {};
  int _request = 0;
  bool _loading = false;
  String? _error;

  SearchSeriesSeason get _season => widget.data.seasons[_selected];
  List<SearchSeriesEpisode> get _episodes =>
      _cache[_season.key] ?? _season.episodes;

  @override
  void initState() {
    super.initState();
    _selected = widget.data.initialSeasonIndex;
    // 内部完整处理失败，异步获取当前季；仅657允许该附加请求。
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _SearchSeriesV3Card oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _request++;
      _cache.clear();
      _selected = widget.data.initialSeasonIndex;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    final season = _season;
    _error = null;
    _loading = false;
    if (season.isUpcoming || _episodes.isNotEmpty) return;
    final loader = widget.onLoadSeason;
    if (loader == null) {
      _error = '加载失败，点击重试';
      return;
    }
    _loading = true;
    try {
      final episodes = await loader(season);
      if (!mounted || request != _request) return;
      final valid = episodes
          .where((episode) =>
              episode.vid.trim().isNotEmpty &&
              episode.seriesId == season.seriesId &&
              episode.number > 0)
          .toList(growable: false);
      if (valid.isEmpty) throw StateError('empty season');
      setState(() {
        _cache[season.key] = valid;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = '加载失败，点击重试';
      });
    }
  }

  void _select(int index) {
    setState(() {
      _selected = index;
      unawaited(_load());
    });
  }

  void _playEpisode(SearchSeriesEpisode episode) {
    final drama = _season.drama;
    if (drama != null && episode.seriesId == _season.seriesId) {
      widget.onPlayEpisode?.call(drama, episode.number);
    }
  }

  void _openSeason() {
    final season = _season;
    if (season.isUpcoming) {
      if (season.routeUrl.isNotEmpty && widget.onOpenLink != null) {
        widget.onOpenLink!(season.routeUrl);
      } else {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('即将上线，敬请期待')));
      }
    } else if (season.drama != null) {
      widget.onPlay(season.drama!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = _SeriesPalette(context);
    final season = _season;
    return Stack(children: [
      // 原 V3 封面从后景顶部突出 16，季/集区域独立组成底部圆角块。
      Positioned.fill(
        top: 16,
        child: DecoratedBox(
          key: const ValueKey('search-series-v3-backdrop'),
          decoration: BoxDecoration(
              color: palette.heroBackground,
              borderRadius: BorderRadius.circular(12)),
        ),
      ),
      Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TvTap(
                key: const ValueKey('search-series-v3-hero'),
                focusNode: widget.focusNode,
                behavior: HitTestBehavior.opaque,
                focusScale: 1,
                onTap: _openSeason,
                child:
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: DeviceProfile.isTv ? 142.5 : 114,
                      height: DeviceProfile.isTv ? 200 : 160,
                      child: ColoredBox(
                        color: palette.placeholder,
                        child: season.cover.isEmpty
                            ? const Icon(Icons.movie_outlined)
                            : Image.network(season.cover,
                                fit: BoxFit.cover,
                                frameBuilder: (_, child, frame, synchronous) =>
                                    synchronous || frame != null
                                        ? child
                                        : const Center(
                                            child: Icon(Icons.movie_outlined)),
                                errorBuilder: (_, __, ___) =>
                                    const Icon(Icons.movie_outlined)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(season.drama?.name ?? season.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: palette.selectedText,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  height: 24 / 16)),
                          const SizedBox(height: 8),
                          if (season.subtitle.isNotEmpty)
                            Text(season.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: palette.subtitle,
                                    fontSize: 12,
                                    height: 16 / 12)),
                          if (season.drama?.intro.isNotEmpty ?? false) ...[
                            const SizedBox(height: 4),
                            Text(season.drama!.intro,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: palette.subtitle,
                                    fontSize: 12,
                                    height: 19 / 12)),
                          ],
                          const SizedBox(height: 8),
                          Container(
                            height: 32,
                            decoration: BoxDecoration(
                                color: const Color(0xFF61F2D0),
                                borderRadius: BorderRadius.circular(6)),
                            alignment: Alignment.center,
                            child: Text(season.isUpcoming ? '即将上线' : '播放',
                                style: const TextStyle(
                                    color: Color(0xFF1B1B1B),
                                    fontSize: 12,
                                    height: 20 / 12,
                                    fontWeight: FontWeight.w500)),
                          ),
                        ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 9),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 108),
              child: Padding(
                padding: const EdgeInsets.only(top: 7, bottom: 12),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SeriesV3Rail(
                        key: const ValueKey('search-series-v3-seasons'),
                        initialIndex: widget.data.initialSeasonIndex,
                        labels: widget.data.seasons
                            .map((item) => item.title)
                            .toList(),
                        selectedIndex: _selected,
                        onTap: _select,
                        keyPrefix: 'search-series-v3-season',
                        episodeStyle: false,
                      ),
                      const SizedBox(height: 13),
                      if (season.isUpcoming)
                        const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text('即将上线，敬请期待'))
                      else if (_loading)
                        const Padding(
                            padding: EdgeInsets.all(12),
                            child: LinearProgressIndicator(
                                key: ValueKey('search-series-v3-loading')))
                      else if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: TvTap(
                            key: const ValueKey('search-series-v3-retry'),
                            onTap: () => setState(() => unawaited(_load())),
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(_error!)),
                          ),
                        )
                      else
                        _SeriesV3Rail(
                          key: ValueKey(
                              'search-series-v3-episodes-${season.key}'),
                          initialIndex: season.initialEpisodeIndex,
                          labels: _episodes
                              .map((episode) => episode.number.toString())
                              .toList(),
                          selectedIndex: season.initialEpisodeIndex,
                          onTap: (index) => _playEpisode(_episodes[index]),
                          keyPrefix: 'search-series-v3-episode',
                          episodeStyle: true,
                        ),
                    ]),
              ),
            ),
          ]),
    ]);
  }
}

class _SeriesV3Rail extends StatefulWidget {
  const _SeriesV3Rail({
    super.key,
    required this.initialIndex,
    required this.labels,
    required this.selectedIndex,
    required this.onTap,
    required this.keyPrefix,
    required this.episodeStyle,
  });

  final int initialIndex;
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onTap;
  final String keyPrefix;
  final bool episodeStyle;

  @override
  State<_SeriesV3Rail> createState() => _SeriesV3RailState();
}

class _SeriesV3RailState extends State<_SeriesV3Rail> {
  late List<FocusNode> _nodes;
  final _scroll = ScrollController();

  double _width(int index) {
    final width = widget.episodeStyle
        ? 53.0
        : widget.labels[index].length > 3
            ? 72.0
            : 64.0;
    return DeviceProfile.isTv ? width * 1.25 : width;
  }

  @override
  void initState() {
    super.initState();
    _nodes = [for (final _ in widget.labels) FocusNode()];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      var offset = 0.0;
      for (var index = 0; index < widget.initialIndex; index++) {
        offset += _width(index) + 8;
      }
      _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void didUpdateWidget(covariant _SeriesV3Rail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.labels.length != widget.labels.length) {
      for (final node in _nodes) {
        node.dispose();
      }
      _nodes = [for (final _ in widget.labels) FocusNode()];
    }
  }

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _SeriesPalette(context);
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        for (var index = 0; index < widget.labels.length; index++)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Focus(
              canRequestFocus: false,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                final key = event.logicalKey;
                if (key != LogicalKeyboardKey.arrowLeft &&
                    key != LogicalKeyboardKey.arrowRight) {
                  return KeyEventResult.ignored;
                }
                final next =
                    index + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
                if (next >= 0 && next < _nodes.length) {
                  _nodes[next].requestFocus();
                }
                return KeyEventResult.handled;
              },
              child: TvTap(
                key: ValueKey('${widget.keyPrefix}-$index'),
                focusNode: _nodes[index],
                behavior: HitTestBehavior.opaque,
                focusScale: 1,
                onTap: () => widget.onTap(index),
                borderRadius: widget.episodeStyle ? 8 : 6,
                child: Container(
                  width: _width(index),
                  height: (widget.episodeStyle ? 52 : 32) *
                      (DeviceProfile.isTv ? 1.25 : 1),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: !widget.episodeStyle && widget.selectedIndex == index
                        ? palette.selectedBackground
                        : palette.tabBackground,
                    borderRadius:
                        BorderRadius.circular(widget.episodeStyle ? 8 : 6),
                  ),
                  alignment: Alignment.center,
                  child: Text(widget.labels[index],
                      maxLines: widget.episodeStyle ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: widget.episodeStyle ? 14 : 12,
                          fontWeight: !widget.episodeStyle &&
                                  widget.selectedIndex == index
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: !widget.episodeStyle &&
                                  widget.selectedIndex == index
                              ? palette.selectedText
                              : palette.chipText)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
