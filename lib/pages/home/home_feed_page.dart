import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import '../../services/device_profile.dart';
import '../../services/download_service.dart';
import '../../widgets/notice_bar.dart';
import '../../widgets/tv_tap.dart';
import '../global_search_page.dart';
import 'continue_watching_row.dart';
import 'drama_list_tab.dart';

/// 首页“首页 / 新剧 / 推荐 / 热播 / 收藏 / 热搜”六个栏目。
class HomeFeedPage extends StatefulWidget {
  const HomeFeedPage({
    super.key,
    required this.apiClient,
    required this.downloadService,
    required this.onTvTopBarFocusChanged,
    this.onShowHistory,
  });
  final ValueChanged<bool> onTvTopBarFocusChanged;

  /// “继续观看”里点“全部”：切到历史页。
  final VoidCallback? onShowHistory;
  final ApiClient apiClient;
  final DownloadService downloadService;

  @override
  State<HomeFeedPage> createState() => HomeFeedPageState();
}

class HomeFeedPageState extends State<HomeFeedPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<FocusNode> _tvTabFocusNodes =
      List.generate(6, (index) => FocusNode(debugLabel: 'TV 栏目 $index'));

  void focusCurrentTvTab() {
    _tvTabFocusNodes[_tabController.index].requestFocus();
  }

  @override
  void initState() {
    super.initState();
    // 首页、新剧、推荐、热播、收藏、热搜。
    _tabController = TabController(length: 6, vsync: this, initialIndex: 0);
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final node in _tvTabFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildTopBar(context),
        NoticeBar(apiClient: widget.apiClient),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildHomeTab(),
              _buildNewPlayTab(),
              _buildRankTab('recommend'),
              _buildRankTab('hotplay'),
              _buildRankTab('followed'),
              _buildRankTab('hotsearch'),
            ]
                .indexed
                .map((entry) => ListenableBuilder(
                      listenable: _tabController,
                      child: entry.$2,
                      builder: (_, child) => ExcludeFocus(
                        // TabBarView 会缓存相邻栏目，隐藏页不能接收方向键焦点。
                        excluding: entry.$1 != _tabController.index,
                        child: child!,
                      ),
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildHomeTab() {
    return DramaListTab(
      apiClient: widget.apiClient,
      downloadService: widget.downloadService,
      enableFilters: false,
      // 电视端暂不显示，避免打乱遥控器的焦点顺序
      header: DeviceProfile.isTv
          ? null
          : ContinueWatchingRow(
              apiClient: widget.apiClient,
              downloadService: widget.downloadService,
              onShowAll: widget.onShowHistory,
            ),
      fetchFunction: (client, offset, sessionId, type) =>
          client.fetchHomePage(offset: offset, sessionId: sessionId),
    );
  }

  Widget _buildNewPlayTab() {
    return DramaListTab(
      apiClient: widget.apiClient,
      downloadService: widget.downloadService,
      enableFilters: false,
      fetchFunction: (client, offset, sessionId, type) async {
        final res = await client.fetchNewPlay(
          offset: offset,
          sessionId: sessionId,
        );
        return HomePageResult(
          offset: res.offset,
          sessionId: res.sessionId,
          count: res.count,
          hasMore: res.hasMore,
          nextOffset: res.nextOffset,
          list: res.list,
        );
      },
    );
  }

  /// 推荐 / 热播 / 收藏 / 热搜：同一种带排名、可按男女频筛选的榜单列表。
  Widget _buildRankTab(String rankType) {
    return DramaListTab(
      apiClient: widget.apiClient,
      downloadService: widget.downloadService,
      enableFilters: true,
      useGridView: false,
      showRanking: true,
      fetchFunction: (client, offset, sessionId, type) async {
        final res = await client.fetchRankList(
          rankType: rankType,
          type: type,
          offset: offset,
          sessionId: sessionId,
        );
        return HomePageResult(
          offset: res.offset,
          sessionId: res.sessionId,
          count: res.count,
          hasMore: res.hasMore,
          nextOffset: res.nextOffset,
          list: res.list,
        );
      },
    );
  }

  Widget _buildTopBar(BuildContext context) {
    if (DeviceProfile.isTv) return _buildTvTopBar(context);
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 0),
        color: Colors.white,
        child: Row(
          children: [
            Expanded(
              child: Container(
                alignment: Alignment.centerLeft,
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  indicatorColor: const Color(0xFFFF2442),
                  indicatorSize: TabBarIndicatorSize.label,
                  indicatorWeight: 2,
                  labelColor: const Color(0xFF333333),
                  unselectedLabelColor: const Color(0xFF999999),
                  labelStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.normal,
                  ),
                  dividerColor: Colors.transparent,
                  overlayColor: WidgetStateProperty.resolveWith((states) {
                    if (DeviceProfile.usesFocusUi &&
                        states.contains(WidgetState.focused)) {
                      return const Color(0xFFFF2442).withAlpha(90);
                    }
                    return Colors.transparent;
                  }),
                  splashFactory: NoSplash.splashFactory,
                  tabAlignment: TabAlignment.start,
                  padding: EdgeInsets.zero,
                  labelPadding: const EdgeInsets.only(right: 24),
                  tabs: const [
                    Tab(text: '首页'),
                    Tab(text: '新剧'),
                    Tab(text: '推荐'),
                    Tab(text: '热播'),
                    Tab(text: '收藏'),
                    Tab(text: '热搜'),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GlobalSearchPage(
                      apiClient: widget.apiClient,
                      downloadService: widget.downloadService,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.search, color: Color(0xFF333333)),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(
                minWidth: 44,
                minHeight: 44,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTvTopBar(BuildContext context) {
    const labels = ['首页', '新剧', '推荐', '热播', '收藏', '热搜'];
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 22, 32, 12),
        child: Row(
          children: [
            const Icon(Icons.play_circle_filled_rounded,
                size: 27, color: Color(0xFFFF2442)),
            const SizedBox(width: 9),
            const Text('龙龙短剧',
                style: TextStyle(
                  color: Color(0xFF242833),
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .5,
                )),
            const SizedBox(width: 36),
            Expanded(
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: widget.onTvTopBarFocusChanged,
                child: ListenableBuilder(
                  listenable: _tabController,
                  builder: (_, __) => Row(
                    children: List.generate(labels.length, (index) {
                      final selected = index == _tabController.index;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TvTap(
                          borderRadius: 14,
                          focusNode: _tvTabFocusNodes[index],
                          focusScale: 1,
                          onTap: () => _tabController.animateTo(index),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 17, vertical: 10),
                            decoration: BoxDecoration(
                              color: selected
                                  ? const Color(0xFFFF2442)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(labels[index],
                                style: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : const Color(0xFF747B88),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                )),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
            TvTap(
              borderRadius: 14,
              focusScale: 1,
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => GlobalSearchPage(
                  apiClient: widget.apiClient,
                  downloadService: widget.downloadService,
                ),
              )),
              child: const Tooltip(
                message: '搜索',
                child: Padding(
                  padding: EdgeInsets.all(11),
                  child: Icon(Icons.search_rounded,
                      color: Color(0xFF424957), size: 23),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
