import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/drama_season.dart';
import '../../models/episode.dart';

// ─── 红果选集面板 ────────────────────────────────────────────────────────
// 依据红果 ShortSeriesEpisodesDialogV2 的布局（ql.xml / aji.xml / ajj.xml /
// e07.xml）与 AlbumCatalogTabListView 参数：
//  · 竖屏：底部弹出，高度 = 屏幕高 × 50%（EpisodeCatalogStyleV671
//    dialogHeightPercent 默认 0.5），顶部 16dp 圆角，底色 #1C1C1C，
//    36×4 拖动条；同时播放画面缩到面板上方（见 PlayerPage）。
//  · 横屏：右侧 390dp 全高侧栏。
//  · 头部：44×62 封面(圆角4) + 剧名 16sp + “›”，下方状态灰字；简介两行。
//  · 分段 Tab：每段 30 集（1-30、31-60…），44dp 高；右侧季数入口，标题/数字显示通过图标切换。
//  · 序号模式 6 列、左右 16dp、间距 8dp；当前集用品牌橙 #FA7705。

const kHgPanelBg = Color(0xFF1C1C1C);
const kHgBrand = Color(0xFFFA7705);
const _kText = Color(0xCCFFFFFF);
const _kGray40 = Color(0x66FFFFFF);
const _kGray70 = Color(0x99FFFFFF);
const _kCellBg = Color(0x0FFFFFFF);
const _kRange = 30;

/// 竖屏选集面板高度占屏幕的比例（红果默认 0.5）
const double kHgEpisodePanelHeightFactor = 0.5;

/// 横屏侧栏宽度（红果 ajj.xml / attributes.width = 390dp）
const double kHgEpisodeSideWidth = 390;

Future<void> showHgEpisodePanel({
  required BuildContext context,
  required bool landscape,
  required String dramaName,
  required String cover,
  required String intro,
  required String status,
  required List<Episode> episodes,
  required ValueListenable<int> episodeNotifier,
  required ValueChanged<int> onSelectEpisode,
  Future<Map<String, String>> Function()? loadTitles,
  Future<DramaSeasons> Function()? loadSeasons,
  int? currentDramaId,
  ValueChanged<DramaSeason>? onSelectSeason,
}) {
  Widget panel(BuildContext context) => HgEpisodePanel(
        landscape: landscape,
        dramaName: dramaName,
        cover: cover,
        intro: intro,
        status: status,
        episodes: episodes,
        episodeNotifier: episodeNotifier,
        loadTitles: loadTitles,
        loadSeasons: loadSeasons,
        currentDramaId: currentDramaId,
        onSelectSeason: (season) {
          Navigator.of(context).pop();
          onSelectSeason?.call(season);
        },
        onSelect: (index) {
          Navigator.of(context).pop();
          onSelectEpisode(index);
        },
      );

  if (landscape) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black.withAlpha(40),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, __) {
        final size = MediaQuery.of(context).size;
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: math.min(size.width, kHgEpisodeSideWidth),
            height: size.height,
            child: Material(color: kHgPanelBg, child: panel(context)),
          ),
        );
      },
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    // 画面缩到面板上方，遮罩透明，点上方画面即关闭
    barrierColor: Colors.transparent,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: false,
    builder: (context) {
      final h = MediaQuery.of(context).size.height;
      return SizedBox(
        height: h * kHgEpisodePanelHeightFactor,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: Material(color: kHgPanelBg, child: panel(context)),
        ),
      );
    },
  );
}

class HgEpisodePanel extends StatefulWidget {
  const HgEpisodePanel({
    super.key,
    required this.landscape,
    required this.dramaName,
    required this.cover,
    required this.intro,
    required this.status,
    required this.episodes,
    required this.episodeNotifier,
    required this.onSelect,
    this.loadTitles,
    this.loadSeasons,
    this.currentDramaId,
    this.onSelectSeason,
  });

  final bool landscape;
  final String dramaName, cover, intro, status;
  final List<Episode> episodes;
  final ValueListenable<int> episodeNotifier;
  final ValueChanged<int> onSelect;
  final Future<Map<String, String>> Function()? loadTitles;
  final Future<DramaSeasons> Function()? loadSeasons;
  final int? currentDramaId;
  final ValueChanged<DramaSeason>? onSelectSeason;

  @override
  State<HgEpisodePanel> createState() => _HgEpisodePanelState();
}

class _HgEpisodePanelState extends State<HgEpisodePanel> {
  late int _range = widget.episodeNotifier.value ~/ _kRange;
  bool _titleMode = false;
  bool _seasonMode = false;
  bool _seasonsLoading = false;
  bool _seasonsFailed = false;
  List<DramaSeason>? _seasons;
  bool _introExpanded = false;
  bool _titleLoading = false;
  String? _titleError;
  Map<String, String>? _titles;
  final _tabs = ScrollController();

  int get _rangeCount => (widget.episodes.length + _kRange - 1) ~/ _kRange;

  @override
  void initState() {
    super.initState();
    if (widget.loadSeasons != null) unawaited(_loadSeasons());
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTabIntoView());
  }

  void _scrollTabIntoView() {
    if (!_tabs.hasClients) return;
    final target =
        (_range * 76.0 - 40).clamp(0.0, _tabs.position.maxScrollExtent);
    _tabs.jumpTo(target);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = widget.landscape ? media.viewPadding.top + 20 : 0.0;
    return Padding(
      padding: EdgeInsets.only(
        top: top,
        bottom: widget.landscape ? 0 : media.viewPadding.bottom,
        right: widget.landscape ? media.viewPadding.right : 0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.landscape)
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0x1AFFFFFF),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          _header(),
          if (widget.intro.trim().isNotEmpty) _intro(),
          _rangeBar(),
          Expanded(
            child: _seasonMode
                ? _seasonContent()
                : ValueListenableBuilder<int>(
                    valueListenable: widget.episodeNotifier,
                    builder: (context, current, _) =>
                        _titleMode ? _titleContent(current) : _grid(current),
                  ),
          ),
        ],
      ),
    );
  }

  /// 剧情简介：默认两行，超出时显示“展开”；展开后最多占面板约 40% 高度，可滚动查看全部。
  Widget _intro() {
    const style = TextStyle(color: _kText, fontSize: 14, height: 1.5);
    final intro = widget.intro.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: LayoutBuilder(builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: intro, style: style),
          maxLines: 2,
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflow = painter.didExceedMaxLines;
        painter.dispose();
        final toggle = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _introExpanded = !_introExpanded),
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_introExpanded ? '收起' : '展开',
                  style: const TextStyle(color: _kGray70, fontSize: 13)),
              Icon(
                  _introExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: _kGray70),
            ]),
          ),
        );
        if (!_introExpanded) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: overflow
                    ? () => setState(() => _introExpanded = true)
                    : null,
                child: Text(intro,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
              ),
              if (overflow) toggle,
            ],
          );
        }
        final maxH = MediaQuery.of(context).size.height * 0.2;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: SingleChildScrollView(child: Text(intro, style: style)),
            ),
            toggle,
          ],
        );
      }),
    );
  }

  Widget _header() {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, widget.landscape ? 0 : 20, 16, 14),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 44,
              height: 62,
              child: widget.cover.isEmpty
                  ? const ColoredBox(color: Color(0x1AFFFFFF))
                  : Image.network(
                      widget.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const ColoredBox(color: Color(0x1AFFFFFF)),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      widget.dramaName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right_rounded,
                      color: _kGray40, size: 18),
                ]),
                const SizedBox(height: 6),
                Text(
                  widget.status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _kGray40, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rangeBar() {
    final n = widget.episodes.length;
    return SizedBox(
      height: 44,
      child: Row(children: [
        Expanded(
          child: _seasonMode
              ? const Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('相关季',
                          style: TextStyle(color: _kText, fontSize: 14))),
                )
              : _rangeCount <= 1
                  ? const SizedBox.shrink()
                  : ListView.separated(
                      controller: _tabs,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _rangeCount,
                      separatorBuilder: (_, __) => const SizedBox(width: 20),
                      itemBuilder: (context, i) {
                        final selected = i == _range;
                        final from = i * _kRange + 1;
                        final to = math.min(n, (i + 1) * _kRange);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _range = i),
                          child: Center(
                            child: Text(
                              '$from-$to',
                              style: TextStyle(
                                color: selected ? Colors.white : _kGray40,
                                fontSize: 14,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
        ),
        if (!_seasonMode)
          IconButton(
            tooltip: _titleMode ? '切换为数字选集' : '切换为标题选集',
            onPressed: () {
              setState(() => _titleMode = !_titleMode);
              if (_titleMode && _titles == null && !_titleLoading) {
                unawaited(_loadTitles());
              }
            },
            icon: Icon(
                _titleMode ? Icons.grid_view_rounded : Icons.notes_rounded,
                color: _kGray70,
                size: 18),
          ),
        if (widget.loadSeasons != null)
          TextButton(
            key: const ValueKey('player-season-toggle'),
            onPressed: () => setState(() => _seasonMode = !_seasonMode),
            style: TextButton.styleFrom(
                foregroundColor: _kGray70,
                padding: const EdgeInsets.symmetric(horizontal: 12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(
                  _seasonMode
                      ? '返回选集'
                      : (_seasons == null ? '选季' : '共${_seasons!.length}季'),
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 2),
              Icon(
                  _seasonMode
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18),
            ]),
          ),
      ]),
    );
  }

  Future<void> _loadSeasons() async {
    final loader = widget.loadSeasons;
    if (loader == null || _seasonsLoading) return;
    setState(() {
      _seasonsLoading = true;
      _seasonsFailed = false;
    });
    try {
      final result = await loader();
      if (!mounted) return;
      final seasons = result.seasons.toList();
      final currentId = widget.currentDramaId;
      if (currentId != null &&
          currentId > 0 &&
          !seasons.any((season) => season.id == currentId)) {
        seasons.add(DramaSeason(
            id: currentId,
            title: widget.dramaName,
            cover: widget.cover,
            order: result.currentSeason > 0 ? result.currentSeason : 1,
            episodeCount: widget.episodes.length));
      }
      seasons.sort((a, b) => a.order.compareTo(b.order));
      setState(() => _seasons = seasons);
    } catch (_) {
      if (mounted) setState(() => _seasonsFailed = true);
    } finally {
      if (mounted) setState(() => _seasonsLoading = false);
    }
  }

  Widget _seasonContent() {
    if (_seasonsLoading) {
      return const Center(
          child: Text('正在加载相关季…',
              style: TextStyle(color: _kGray70, fontSize: 14)));
    }
    if (_seasonsFailed) {
      return Center(
          child: TextButton(
              onPressed: _loadSeasons,
              child: const Text('相关季加载失败，点击重试',
                  style: TextStyle(color: _kGray70))));
    }
    final seasons = _seasons ?? const <DramaSeason>[];
    if (seasons.isEmpty) {
      return const Center(
          child: Text('暂无相关季', style: TextStyle(color: _kGray70)));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: seasons.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final season = seasons[index];
        final current = season.id == widget.currentDramaId;
        return Material(
          color: current ? const Color(0x1AFA7705) : _kCellBg,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: ValueKey('player-season-${season.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              if (current) {
                setState(() => _seasonMode = false);
                return;
              }
              widget.onSelectSeason?.call(season);
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Container(
                  width: 52,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: current
                          ? const Color(0x26FA7705)
                          : const Color(0x0FFFFFFF),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text('第${season.order}季',
                      style: TextStyle(
                          color: current ? kHgBrand : _kText,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Text(
                          season.title.isEmpty
                              ? '第${season.order}季'
                              : season.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: current ? kHgBrand : _kText,
                              fontSize: 14)),
                      const SizedBox(height: 4),
                      Text(
                          current
                              ? '正在播放'
                              : (season.episodeCount > 0
                                  ? '共${season.episodeCount}集'
                                  : '点击播放'),
                          style:
                              const TextStyle(color: _kGray40, fontSize: 12)),
                    ])),
                const SizedBox(width: 8),
                Icon(
                    current
                        ? Icons.equalizer_rounded
                        : Icons.play_arrow_rounded,
                    color: current ? kHgBrand : _kGray70,
                    size: 20),
              ]),
            ),
          ),
        );
      },
    );
  }

  List<int> get _indexesInRange {
    final from = _range * _kRange;
    final to = math.min(widget.episodes.length, from + _kRange);
    return [for (var i = from; i < to; i++) i];
  }

  Widget _grid(int current) {
    final indexes = _indexesInRange;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: indexes.length,
      itemBuilder: (context, i) {
        final index = indexes[i];
        final selected = index == current;
        return GestureDetector(
          key: ValueKey('episode-$index'),
          onTap: () => widget.onSelect(index),
          child: Container(
            decoration: BoxDecoration(
              color: selected ? const Color(0x1AFA7705) : _kCellBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Stack(children: [
              Center(
                child: Text(
                  '${widget.episodes[index].index}',
                  style: TextStyle(
                    color: selected ? kHgBrand : _kText,
                    fontSize: 16,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected)
                const Positioned(
                  right: 3,
                  top: 3,
                  child:
                      Icon(Icons.equalizer_rounded, color: kHgBrand, size: 12),
                ),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _loadTitles() async {
    final loader = widget.loadTitles;
    if (loader == null || _titleLoading) return;
    setState(() {
      _titleLoading = true;
      _titleError = null;
    });
    try {
      final titles = await loader();
      if (mounted) setState(() => _titles = titles);
    } catch (_) {
      if (mounted) setState(() => _titleError = '分集标题加载失败，点击重试');
    } finally {
      if (mounted) setState(() => _titleLoading = false);
    }
  }

  Widget _titleContent(int current) => Column(children: [
        if (_titleLoading)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('正在加载分集标题…',
                  style: TextStyle(color: _kGray70, fontSize: 12))),
        if (_titleError != null)
          TextButton(
              onPressed: _loadTitles,
              child: Text(_titleError!,
                  style: const TextStyle(color: _kGray70, fontSize: 12))),
        if (_titles != null && _titles!.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('此剧暂未提供分集标题',
                  style: TextStyle(color: _kGray70, fontSize: 12))),
        Expanded(child: _titleList(current)),
      ]);

  Widget _titleList(int current) {
    final indexes = _indexesInRange;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: indexes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final index = indexes[i];
        final ep = widget.episodes[index];
        final selected = index == current;
        final name = (_titles?[ep.url] ?? ep.name).trim();
        return GestureDetector(
          onTap: () => widget.onSelect(index),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? const Color(0x1AFA7705) : _kCellBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(children: [
              if (selected) ...[
                const Icon(Icons.equalizer_rounded, color: kHgBrand, size: 14),
                const SizedBox(width: 6),
              ],
              Text('第${ep.index}集',
                  style: TextStyle(
                      color: selected ? kHgBrand : _kText,
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500)),
              if (name.isNotEmpty && name != '第${ep.index}集') ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: selected ? kHgBrand : _kGray70, fontSize: 14)),
                ),
              ],
            ]),
          ),
        );
      },
    );
  }
}
