import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/favorite_drama_store.dart';
import 'app_notice.dart';
import 'tv_tap.dart';
import '../pages/drama_detail_page.dart';

class FavoriteDramaCarousel extends StatefulWidget {
  const FavoriteDramaCarousel(
      {super.key,
      required this.apiClient,
      this.downloadService,
      this.showAll = false,
      this.onViewAll,
      this.managing = false,
      this.selectedKeys = const <String>{},
      this.onSelect,
      this.onItemsChanged});
  final ApiClient apiClient;
  final DownloadService? downloadService;
  final bool showAll;
  final VoidCallback? onViewAll;
  final bool managing;
  final Set<String> selectedKeys;
  final ValueChanged<Drama>? onSelect;
  final ValueChanged<List<Drama>>? onItemsChanged;

  @override
  State<FavoriteDramaCarousel> createState() => _FavoriteDramaCarouselState();
}

class _FavoriteDramaCarouselState extends State<FavoriteDramaCarousel> {
  List<Drama> _items = [];
  bool _loading = true;
  String? _error;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    FavoriteDramaStore.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    FavoriteDramaStore.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    try {
      final items = await FavoriteDramaStore.load();
      if (!mounted || revision != _revision) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
      widget.onItemsChanged?.call(List.unmodifiable(items));
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() {
          _loading = false;
          _error = '读取收藏失败，请重试';
        });
      }
    }
  }

  Future<void> _remove(Drama drama) async {
    try {
      await FavoriteDramaStore.remove(drama);
    } catch (_) {
      if (mounted) {
        showAppNotice(context,
            message: '取消收藏失败，请重试', kind: AppNoticeKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_error != null) {
      return Padding(
          padding: const EdgeInsets.all(12),
          child: TextButton(onPressed: _load, child: Text(_error!)));
    }
    if (_items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 22),
        child: Align(
            alignment: Alignment.centerLeft,
            child: Text('还没有收藏，去短剧详情页收藏喜欢的剧吧',
                style: TextStyle(fontSize: 13, color: Color(0xFF969CA7)))),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(1);
      double cardHeight(double width) =>
          width * 1.5 + 10 + math.max(32.0, 16.8 * textScale);
      if (widget.showAll) {
        final columns = ((constraints.maxWidth - 32) / 112).floor().clamp(2, 8);
        final width =
            (constraints.maxWidth - 32 - 10 * (columns - 1)) / columns;
        return GridView.builder(
          key: const ValueKey('all-favorite-dramas'),
          padding: const EdgeInsets.all(16),
          itemCount: _items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            mainAxisExtent: cardHeight(width),
          ),
          itemBuilder: (_, index) => _buildCard(_items[index], width),
        );
      }
      final cardWidth = ((constraints.maxWidth - 44) / 3.3).clamp(80.0, 116.0);
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(children: [
                Expanded(
                    child: Text('我的收藏 · ${_items.length}部',
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF323844)))),
                TextButton(
                  onPressed: widget.onViewAll,
                  style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF969CA7),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(48, 32)),
                  child: const Text('全部', style: TextStyle(fontSize: 12)),
                ),
              ]),
            ),
            SizedBox(
              height: cardHeight(cardWidth),
              child: ListView.separated(
                key: const ValueKey('favorite-drama-carousel'),
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: math.min(_items.length, 10),
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) =>
                    _buildCard(_items[index], cardWidth),
              ),
            ),
          ]);
    });
  }

  Widget _buildCard(Drama drama, double width) => SizedBox(
        width: width,
        child: TvTap(
          key: ValueKey(FavoriteDramaStore.keyOf(drama)),
          ink: true,
          borderRadius: 8,
          focusScale: 1,
          onTap: widget.managing
              ? () => widget.onSelect?.call(drama)
              : () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => DramaDetailPage(
                        drama: drama,
                        apiClient: widget.apiClient,
                        downloadService: widget.downloadService),
                  )),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: ColoredBox(
                  color: const Color(0xFFF2F3F5),
                  child: drama.cover.isEmpty
                      ? const Icon(Icons.movie_outlined,
                          color: Color(0xFFB3B8C2), size: 32)
                      : Image.network(drama.cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                              Icons.movie_outlined,
                              color: Color(0xFFB3B8C2),
                              size: 32)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                  child: Text(
                drama.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    color: Color(0xFF303642)),
              )),
              if (widget.managing)
                Semantics(
                  selected: widget.selectedKeys
                      .contains(FavoriteDramaStore.keyOf(drama)),
                  child: SizedBox.square(
                      dimension: 32,
                      child: Icon(
                        widget.selectedKeys
                                .contains(FavoriteDramaStore.keyOf(drama))
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: widget.selectedKeys
                                .contains(FavoriteDramaStore.keyOf(drama))
                            ? const Color(0xFFFF2442)
                            : const Color(0xFFB3B8C2),
                      )),
                )
              else
                IconButton(
                  tooltip: '取消收藏',
                  onPressed: () => _remove(drama),
                  constraints:
                      const BoxConstraints.tightFor(width: 32, height: 32),
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  iconSize: 18,
                  icon:
                      const Icon(Icons.star_rounded, color: Color(0xFFC29232)),
                ),
            ]),
          ]),
        ),
      );
}
