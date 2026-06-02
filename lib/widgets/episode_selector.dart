import 'package:flutter/material.dart';
import '../models/episode.dart';

class EpisodeSelector extends StatefulWidget {
  const EpisodeSelector({
    super.key,
    required this.episodes,
    required this.activeIndex,
    required this.onSelect,
  });

  final List<Episode> episodes;
  final int activeIndex;
  final ValueChanged<int> onSelect;

  @override
  State<EpisodeSelector> createState() => _EpisodeSelectorState();
}

class _EpisodeSelectorState extends State<EpisodeSelector> {
  // 每页显示的集数 (30集一组)
  static const int _pageSize = 30;

  // 当前选中的分页索引
  int _currentTabIndex = 0;

  final ScrollController _tabScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _currentTabIndex = (widget.activeIndex / _pageSize).floor();

    // 延迟一帧滚动 Tab 到可见区域
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActiveTab();
    });
  }

  @override
  void didUpdateWidget(EpisodeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex) {
      final newTabIndex = (widget.activeIndex / _pageSize).floor();
      if (newTabIndex != _currentTabIndex) {
        setState(() {
          _currentTabIndex = newTabIndex;
        });
        _scrollToActiveTab();
      }
    }
  }

  @override
  void dispose() {
    _tabScrollController.dispose();
    super.dispose();
  }

  void _scrollToActiveTab() {
    if (!_tabScrollController.hasClients) return;
    const double estimatedItemWidth = 85.0;
    final double targetOffset =
        (_currentTabIndex * estimatedItemWidth) -
        (MediaQuery.of(context).size.width / 2) +
        (estimatedItemWidth / 2);

    final double maxScroll = _tabScrollController.position.maxScrollExtent;
    final double scrollTo = targetOffset.clamp(0.0, maxScroll);

    _tabScrollController.animateTo(
      scrollTo,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalEpisodes = widget.episodes.length;
    final totalTabs = (totalEpisodes / _pageSize).ceil();
    final hasTabs = totalTabs > 1;

    // 当前分页下的剧集列表
    final start = _currentTabIndex * _pageSize;
    final end = (start + _pageSize) > totalEpisodes
        ? totalEpisodes
        : (start + _pageSize);
    final currentEpisodes = widget.episodes.sublist(start, end);

    return Column(
      children: [
        if (hasTabs)
          Container(
            height: 40,
            margin: const EdgeInsets.fromLTRB(0, 4, 0, 12),
            child: ListView.separated(
              controller: _tabScrollController,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              itemCount: totalTabs,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final tabStart = index * _pageSize + 1;
                final tabEnd = (index + 1) * _pageSize;
                final displayEnd = tabEnd > totalEpisodes
                    ? totalEpisodes
                    : tabEnd;
                final isSelected = index == _currentTabIndex;

                return Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF171717)
                          : Colors.transparent, // 选中用深邃黑
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ]
                          : null,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => setState(() => _currentTabIndex = index),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            '$tabStart-$displayEnd',
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : const Color(0xFF757575),
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: GridView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.35,
            ),
            itemCount: currentEpisodes.length,
            itemBuilder: (context, index) {
              final episode = currentEpisodes[index];
              final globalIndex = start + index;
              final isActive = globalIndex == widget.activeIndex;

              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  gradient: isActive
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF333333), // 略浅的黑
                            Color(0xFF111111), // 深黑
                          ],
                        )
                      : null,
                  color: isActive ? null : const Color(0xFFF3F4F6), // 浅灰背景
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                  border: isActive
                      ? Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                          width: 1,
                        )
                      : null,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => widget.onSelect(globalIndex),
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Text(
                          '${episode.index}',
                          style: TextStyle(
                            color: isActive
                                ? const Color(0xFFFAFAFA)
                                : const Color(0xFF4B5563),
                            fontWeight: isActive
                                ? FontWeight.w700
                                : FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        // 正在播放的动态标识（静态模拟）
                        if (isActive)
                          Positioned(
                            bottom: 6,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildMusicBar(3),
                                const SizedBox(width: 1),
                                _buildMusicBar(5),
                                const SizedBox(width: 1),
                                _buildMusicBar(2),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // 模拟播放中的律动条
  Widget _buildMusicBar(double height) {
    return Container(
      width: 2,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF4ADE80), // 绿色律动条，增加活力
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}
