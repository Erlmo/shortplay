import 'package:flutter/material.dart';

import '../models/episode.dart';
import '../services/device_profile.dart';
import 'tv_tap.dart';

class EpisodeSelector extends StatefulWidget {
  const EpisodeSelector({
    super.key,
    required this.episodes,
    required this.activeIndex,
    required this.onSelect,
    this.selectedIndexes,
    this.disabledLabels = const {},
    this.autofocusActive = true,
    this.horizontalPadding = 20,
    this.dark = false,
    this.softStyle = false,
    this.embedded = false,
  });

  final List<Episode> episodes;
  final int activeIndex;
  final ValueChanged<int> onSelect;

  /// 非 null 时复用相同分页与网格，改为多选下载模式。
  final Set<int>? selectedIndexes;
  final Map<int, String> disabledLabels;

  /// 电视/桌面上打开时是否自动选中当前集（详情页嵌入时关闭，让“播放”按钮先得焦点）。
  final bool autofocusActive;
  final double horizontalPadding;

  /// 深色样式（电视侧边面板，和播放设置面板统一）
  final bool dark;

  /// 详情页使用浅色分组和轻量选中态。
  final bool softStyle;

  /// 详情页嵌入外层滚动，完整展示当前分组，避免嵌套滚动。
  final bool embedded;

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
    _currentTabIndex =
        (widget.activeIndex.clamp(0, 1 << 30) / _pageSize).floor();

    // 延迟一帧滚动 Tab 到可见区域
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActiveTab();
    });
  }

  @override
  void didUpdateWidget(EpisodeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex) {
      final newTabIndex =
          (widget.activeIndex.clamp(0, 1 << 30) / _pageSize).floor();
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
    if (!mounted || !_tabScrollController.hasClients) return;
    const double estimatedItemWidth = 85.0;
    final double targetOffset = (_currentTabIndex * estimatedItemWidth) -
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
    final tvLight = DeviceProfile.isTv && !widget.dark;
    final lightStyle = !widget.dark && (DeviceProfile.isTv || widget.softStyle);
    final totalEpisodes = widget.episodes.length;
    final totalTabs = (totalEpisodes / _pageSize).ceil();
    final hasTabs = totalTabs > 1;

    // 当前分页下的剧集列表
    final start = (_currentTabIndex * _pageSize).clamp(0, totalEpisodes);
    final end = (start + _pageSize) > totalEpisodes
        ? totalEpisodes
        : (start + _pageSize);
    final currentEpisodes = widget.episodes.sublist(start, end);

    return Column(
      children: [
        if (hasTabs)
          Container(
            height: lightStyle ? 34 : 40,
            margin: EdgeInsets.fromLTRB(0, 4, 0, lightStyle ? 8 : 12),
            child: ListView.separated(
              controller: _tabScrollController,
              padding:
                  EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
              scrollDirection: Axis.horizontal,
              itemCount: totalTabs,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final tabStart = index * _pageSize + 1;
                final tabEnd = (index + 1) * _pageSize;
                final displayEnd =
                    tabEnd > totalEpisodes ? totalEpisodes : tabEnd;
                final isSelected = index == _currentTabIndex;

                return Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? (lightStyle
                              ? const Color(0xFFFFF1F0)
                              : widget.dark
                                  ? Colors.white
                                  : const Color(0xFF171717))
                          : Colors.transparent, // 选中用深邃黑
                      borderRadius:
                          BorderRadius.circular(widget.softStyle ? 10 : 20),
                      boxShadow: isSelected && !lightStyle
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
                      child: TvTap(
                        ink: true,
                        focusScale: 1,
                        onTap: () => setState(() => _currentTabIndex = index),
                        borderRadius: 20,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            '$tabStart-$displayEnd',
                            style: TextStyle(
                              color: isSelected
                                  ? (lightStyle
                                      ? const Color(0xFFFF2442)
                                      : widget.dark
                                          ? Colors.black
                                          : Colors.white)
                                  : (widget.dark
                                      ? Colors.white60
                                      : const Color(0xFF757575)),
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
        if (widget.embedded)
          _buildGrid(tvLight, lightStyle, currentEpisodes, start)
        else
          Expanded(
              child: _buildGrid(tvLight, lightStyle, currentEpisodes, start)),
      ],
    );
  }

  Widget _buildGrid(bool tvLight, bool lightStyle,
          List<Episode> currentEpisodes, int start) =>
      GridView.builder(
        primary: widget.embedded ? false : null,
        shrinkWrap: widget.embedded,
        physics: widget.embedded
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
            widget.horizontalPadding, 0, widget.horizontalPadding, 12),
        gridDelegate: tvLight
            ? const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 96,
                mainAxisExtent: 44,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              )
            : const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 6,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.35,
              ),
        itemCount: currentEpisodes.length,
        itemBuilder: (context, index) {
          final episode = currentEpisodes[index];
          final globalIndex = start + index;
          final multiSelect = widget.selectedIndexes != null;
          final isActive = multiSelect
              ? widget.selectedIndexes!.contains(globalIndex)
              : globalIndex == widget.activeIndex;
          final disabledLabel = widget.disabledLabels[globalIndex];

          return Semantics(
            label:
                '第${episode.index}集${disabledLabel == null ? '' : '，$disabledLabel'}',
            selected: isActive,
            enabled: disabledLabel == null,
            child: AnimatedContainer(
              key: ValueKey('episode-$globalIndex'),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                gradient: isActive
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: widget.dark || lightStyle
                            ? widget.softStyle
                                ? const [Color(0xFFFF6860), Color(0xFFFF6860)]
                                : const [Color(0xFFFF2E55), Color(0xFFFF5656)]
                            : const [
                                Color(0xFF333333), // 略浅的黑
                                Color(0xFF111111), // 深黑
                              ],
                      )
                    : null,
                color: isActive
                    ? null
                    : (widget.dark
                        ? Colors.white.withAlpha(22)
                        : const Color(0xFFF3F4F6)), // 浅灰背景
                borderRadius: BorderRadius.circular(8),
                boxShadow: isActive && !lightStyle
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
                child: TvTap(
                  ink: true,
                  // 电视上打开选集时默认选中当前集
                  autofocus: isActive &&
                      widget.autofocusActive &&
                      DeviceProfile.usesFocusUi,
                  onTap: disabledLabel == null
                      ? () => widget.onSelect(globalIndex)
                      : null,
                  borderRadius: 8,
                  ringColor: widget.dark ? Colors.white : null,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        '${episode.index}',
                        style: TextStyle(
                          color: isActive
                              ? const Color(0xFFFAFAFA)
                              : (widget.dark
                                  ? Colors.white70
                                  : const Color(0xFF4B5563)),
                          fontWeight:
                              isActive ? FontWeight.w700 : FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      // 正在播放的动态标识（静态模拟）
                      if (disabledLabel != null)
                        Positioned(
                          bottom: 1,
                          child: Text(disabledLabel,
                              style: const TextStyle(
                                  fontSize: 8, color: Color(0xFF999999))),
                        ),
                      if (multiSelect && isActive)
                        const Positioned(
                          right: 2,
                          top: 2,
                          child: Icon(Icons.check_circle,
                              size: 12, color: Color(0xFF4ADE80)),
                        ),
                      if (!multiSelect && isActive)
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
            ),
          );
        },
      );

  // 播放中的律动标识。
  Widget _buildMusicBar(double height) {
    return Container(
      width: 2,
      height: height,
      decoration: BoxDecoration(
        color: widget.softStyle ? Colors.white : const Color(0xFF4ADE80),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}
