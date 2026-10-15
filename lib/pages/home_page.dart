import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/drama.dart';
import '../services/api_client.dart';
import '../services/app_update_service.dart';
import '../services/download_service.dart';
import '../widgets/notice_bar.dart';
import 'cache_page.dart';
import 'drama_detail_page.dart';
import 'global_search_page.dart';
import 'play_history_page.dart';
import 'settings_page.dart';
import '../widgets/tv_tap.dart';
import '../services/device_profile.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.apiClient,
    required this.downloadService,
    this.appUpdateService,
  });

  final ApiClient apiClient;
  final DownloadService downloadService;
  final AppUpdateService? appUpdateService;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  late final List<Widget> _pages;

  // GlobalKey用于访问PlayHistoryPage的state，实现tab切换时刷新
  final _playHistoryKey = GlobalKey<PlayHistoryPageState>();

  @override
  void initState() {
    super.initState();
    _pages = [
      _HomeFeedPage(
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
      ),
      PlayHistoryPage(
        key: _playHistoryKey,
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
      ),
      CachePage(
        downloadService: widget.downloadService,
        apiClient: widget.apiClient,
      ),
      SettingsPage(
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
        appUpdateService: widget.appUpdateService,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          DeviceProfile.isTv ? const Color(0xFFF4F5F8) : Colors.white,
      body: IndexedStack(
        index: _currentIndex,
        children: _pages.indexed
            .map((entry) => ExcludeFocus(
                  excluding: entry.$1 != _currentIndex,
                  child: entry.$2,
                ))
            .toList(),
      ),
      bottomNavigationBar: DeviceProfile.isTv
          ? _buildTvNavigation()
          : Theme(
              data: ThemeData(
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
              ),
              child: BottomNavigationBar(
                currentIndex: _currentIndex,
                onTap: (index) {
                  setState(() {
                    _currentIndex = index;
                  });
                  // 当切换到播放记录tab时，刷新数据以显示最新的播放记录
                  if (index == 1) {
                    _playHistoryKey.currentState?.refresh();
                  }
                },
                type: BottomNavigationBarType.fixed,
                backgroundColor: Colors.white,
                elevation: 0,
                selectedItemColor: Colors.black,
                unselectedItemColor: const Color(0xFF999999),
                selectedFontSize: 10,
                unselectedFontSize: 10,
                showSelectedLabels: true,
                showUnselectedLabels: true,
                items: [
                  BottomNavigationBarItem(
                    icon: SvgPicture.asset(
                      'assets/icons/nav_home.svg',
                      width: 28,
                      height: 28,
                      colorFilter: const ColorFilter.mode(
                        Color(0xFF999999),
                        BlendMode.srcIn,
                      ),
                    ),
                    activeIcon: SvgPicture.asset(
                      'assets/icons/nav_home_active.svg',
                      width: 28,
                      height: 28,
                    ),
                    label: '首页',
                  ),
                  BottomNavigationBarItem(
                    icon: SvgPicture.asset(
                      'assets/icons/nav_history.svg',
                      width: 28,
                      height: 28,
                      colorFilter: const ColorFilter.mode(
                        Color(0xFF999999),
                        BlendMode.srcIn,
                      ),
                    ),
                    activeIcon: SvgPicture.asset(
                      'assets/icons/nav_history_active.svg',
                      width: 28,
                      height: 28,
                    ),
                    label: '历史',
                  ),
                  BottomNavigationBarItem(
                    icon: SvgPicture.asset(
                      'assets/icons/nav_cache.svg',
                      width: 28,
                      height: 28,
                      colorFilter: const ColorFilter.mode(
                        Color(0xFF999999),
                        BlendMode.srcIn,
                      ),
                    ),
                    activeIcon: SvgPicture.asset(
                      'assets/icons/nav_cache_active.svg',
                      width: 28,
                      height: 28,
                    ),
                    label: '缓存',
                  ),
                  const BottomNavigationBarItem(
                    icon: Icon(
                      Icons.settings_outlined,
                      size: 28,
                      color: Color(0xFF999999),
                    ),
                    activeIcon: Icon(
                      Icons.settings_rounded,
                      size: 28,
                      color: Colors.black,
                    ),
                    label: '设置',
                  ),
                ],
              ),
            ),
    );
  }

  void _selectTvPage(int index) {
    setState(() => _currentIndex = index);
    if (index == 1) _playHistoryKey.currentState?.refresh();
  }

  Widget _buildTvNavigation() {
    const labels = ['首页', '历史', '缓存', '设置'];
    const icons = [
      Icons.home_outlined,
      Icons.history_rounded,
      Icons.download_for_offline_outlined,
      Icons.settings_outlined,
    ];
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(24, 10, 24, 14),
      child: Center(
        heightFactor: 1,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE6E9EF)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(labels.length, (index) {
              final selected = index == _currentIndex;
              final color =
                  selected ? const Color(0xFFFF2442) : const Color(0xFF747B88);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: TvTap(
                  borderRadius: 16,
                  focusScale: 1,
                  onTap: () => _selectTvPage(index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 112,
                    height: 42,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFFFFF0F3)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icons[index], color: color, size: 21),
                        const SizedBox(width: 8),
                        Text(labels[index],
                            style: TextStyle(
                              color: color,
                              fontSize: 14,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w500,
                            )),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _HomeFeedPage extends StatefulWidget {
  const _HomeFeedPage({required this.apiClient, required this.downloadService});
  final ApiClient apiClient;
  final DownloadService downloadService;

  @override
  State<_HomeFeedPage> createState() => _HomeFeedPageState();
}

class _HomeFeedPageState extends State<_HomeFeedPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    // 5个 Tab: 首页(原发现), 新剧(原关注), 推荐(原杭州), 热播(新增), 飙升(新增)
    _tabController = TabController(length: 5, vsync: this, initialIndex: 0);
  }

  @override
  void dispose() {
    _tabController.dispose();
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
              _DramaListTab(
                apiClient: widget.apiClient,
                downloadService: widget.downloadService,
                enableFilters: false,
                fetchFunction: (client, offset, sessionId, type) =>
                    client.fetchHomePage(offset: offset, sessionId: sessionId),
              ),
              _DramaListTab(
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
              ),
              _DramaListTab(
                apiClient: widget.apiClient,
                downloadService: widget.downloadService,
                enableFilters: true,
                useGridView: false,
                showRanking: true, // 显示排名
                fetchFunction: (client, offset, sessionId, type) async {
                  final res = await client.fetchRankList(
                    rankType: 'recommend',
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
              ),
              _DramaListTab(
                apiClient: widget.apiClient,
                downloadService: widget.downloadService,
                enableFilters: true,
                useGridView: false,
                showRanking: true, // 显示排名
                fetchFunction: (client, offset, sessionId, type) async {
                  final res = await client.fetchRankList(
                    rankType: 'hotplay',
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
              ),
              _DramaListTab(
                apiClient: widget.apiClient,
                downloadService: widget.downloadService,
                enableFilters: true,
                useGridView: false,
                showRanking: true, // 显示排名
                fetchFunction: (client, offset, sessionId, type) async {
                  final res = await client.fetchRankList(
                    rankType: 'rising',
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
              ),
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
                    Tab(text: '飙升'),
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
    const labels = ['首页', '新剧', '推荐', '热播', '飙升'];
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
              child: ListenableBuilder(
                listenable: _tabController,
                builder: (_, __) => Row(
                  children: List.generate(labels.length, (index) {
                    final selected = index == _tabController.index;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TvTap(
                        borderRadius: 14,
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

// 通用的列表 Tab
class _DramaListTab extends StatefulWidget {
  const _DramaListTab({
    required this.apiClient,
    required this.fetchFunction,
    this.downloadService,
    this.enableFilters = false,
    this.useGridView = true,
    this.showRanking = false,
  });

  final ApiClient apiClient;
  final DownloadService? downloadService;
  final bool enableFilters;
  final bool useGridView;
  final bool showRanking;
  final Future<HomePageResult> Function(
    ApiClient client,
    int? offset,
    String? sessionId,
    String type,
  ) fetchFunction;

  @override
  State<_DramaListTab> createState() => _DramaListTabState();
}

class _DramaListTabState extends State<_DramaListTab>
    with AutomaticKeepAliveClientMixin {
  final List<Drama> _dramas = [];
  bool _isLoading = false;
  bool _hasMore = true;
  String? _sessionId;
  int? _nextOffset;
  final _scrollController = ScrollController();

  // Filter state
  String _currentType = 'all';
  final List<String> _filters = ['全部', '男频', '女频'];
  final Map<String, String> _filterMap = {
    '全部': 'all',
    '男频': 'male',
    '女频': 'female',
  };

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadData();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      if (!_isLoading && _hasMore) {
        _loadMore();
      }
    }
  }

  Future<void> _loadData() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final result = await widget.fetchFunction(
        widget.apiClient,
        null,
        null,
        _currentType,
      );
      if (mounted) {
        setState(() {
          _dramas
            ..clear()
            ..addAll(result.list);
          _sessionId = result.sessionId;
          _nextOffset = result.nextOffset;
          _hasMore = result.hasMore;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    setState(() => _isLoading = true);

    try {
      final result = await widget.fetchFunction(
        widget.apiClient,
        _nextOffset,
        _sessionId,
        _currentType,
      );
      if (mounted) {
        setState(() {
          _dramas.addAll(result.list);
          _sessionId = result.sessionId;
          _nextOffset = result.nextOffset;
          _hasMore = result.hasMore;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onFilterChanged(String displayFilter) {
    final newType = _filterMap[displayFilter]!;
    if (_currentType == newType) return;

    setState(() {
      _currentType = newType;
      _dramas.clear();
      _isLoading = false;
      _hasMore = true;
      _sessionId = null;
      _nextOffset = null;
    });
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        if (widget.enableFilters)
          Container(
            height: 34,
            margin: const EdgeInsets.only(top: 4, bottom: 4),
            color: DeviceProfile.isTv ? Colors.transparent : Colors.white,
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                  horizontal: DeviceProfile.isTv ? 32 : 16),
              scrollDirection: Axis.horizontal,
              itemCount: _filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final filter = _filters[index];
                final isSelected = _filterMap[filter] == _currentType;
                return Center(
                  child: TvTap(
                    borderRadius: 20,
                    onTap: () => _onFilterChanged(filter),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF333333)
                            : const Color(0xFFF5F5F7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        filter,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w500,
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF666666),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: _dramas.isEmpty && _isLoading
              ? const Center(child: CupertinoActivityIndicator(radius: 12))
              : RefreshIndicator(
                  onRefresh: () async {
                    setState(() {
                      _dramas.clear();
                      _sessionId = null;
                      _nextOffset = null;
                      _hasMore = true;
                    });
                    await _loadData();
                  },
                  color: const Color(0xFFFF2442),
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    slivers: [
                      SliverPadding(
                        padding: DeviceProfile.isTv
                            ? const EdgeInsets.fromLTRB(32, 12, 32, 20)
                            : widget.useGridView
                                ? const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  )
                                : EdgeInsets.zero,
                        sliver: widget.useGridView
                            ? SliverGrid(
                                gridDelegate: DeviceProfile.usesFocusUi
                                    // 电视/桌面：按宽度自适应列数，避免两列海报被拉满整屏
                                    ? const SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: 200,
                                        childAspectRatio: 0.68,
                                        crossAxisSpacing: 16,
                                        mainAxisSpacing: 16,
                                      )
                                    : const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 2,
                                        childAspectRatio: 0.68,
                                        crossAxisSpacing: 8,
                                        mainAxisSpacing: 8,
                                      ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  return _XHSCard(
                                    drama: _dramas[index],
                                    apiClient: widget.apiClient,
                                    downloadService: widget.downloadService,
                                  );
                                }, childCount: _dramas.length),
                              )
                            : SliverList(
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  return _RankListItem(
                                    drama: _dramas[index],
                                    apiClient: widget.apiClient,
                                    downloadService: widget.downloadService,
                                    rank: widget.showRanking ? index + 1 : null,
                                  );
                                }, childCount: _dramas.length),
                              ),
                      ),
                      SliverToBoxAdapter(child: _buildFooter()),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    if (_dramas.isEmpty) return const SizedBox.shrink();

    if (_isLoading) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        alignment: Alignment.center,
        child: const CupertinoActivityIndicator(radius: 10),
      );
    }

    if (!_hasMore) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        alignment: Alignment.center,
        child: const Text(
          '没有更多了',
          style: TextStyle(color: Color(0xFF999999), fontSize: 12),
        ),
      );
    }

    return const SizedBox(height: 32);
  }
}

// 排行榜列表项组件
class _RankListItem extends StatelessWidget {
  const _RankListItem({
    required this.drama,
    required this.apiClient,
    this.downloadService,
    this.rank,
  });

  final Drama drama;
  final ApiClient apiClient;
  final DownloadService? downloadService;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    return TvTap(
      ink: true,
      borderRadius: 0,
      focusScale: 1.0,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DramaDetailPage(
              drama: drama,
              apiClient: apiClient,
              downloadService: downloadService,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: DeviceProfile.isTv ? BorderRadius.circular(12) : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面图 + 排名
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 85,
                height: 113,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: drama.cover,
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) =>
                          Container(color: Colors.grey[200]),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _getRankColor(rank!),
                          borderRadius: const BorderRadius.only(
                            bottomRight: Radius.circular(6),
                          ),
                        ),
                        child: Text(
                          '$rank',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 右侧信息
            Expanded(
              child: SizedBox(
                height: 113,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // 第一行：标题 + 推荐
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            drama.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1D1D1F),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.whatshot,
                              size: 12,
                              color: Color(0xFFFF7D27),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${drama.score}分推荐',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFFF7D27),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // 第二行：副标题 (分类·集数·作者)
                    Text(
                      drama.subTitle ?? '都市 · 80集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF86868B),
                      ),
                    ),

                    // 第三行：描述/简介
                    Text(
                      (drama.intro.isNotEmpty ? drama.intro : '暂无简介'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF86868B),
                        height: 1.3,
                      ),
                    ),

                    // 第四行：统计标签
                    Row(
                      children: [
                        if (drama.recText != null)
                          _buildStatTag(drama.recText!),
                        if (drama.recText != null) const SizedBox(width: 6),
                        if (drama.secondaryInfoList != null &&
                            drama.secondaryInfoList!.isNotEmpty &&
                            drama.secondaryInfoList!.length > 1)
                          _buildStatTag(drama.secondaryInfoList![1].content)
                        else if (drama.secondaryInfoList != null &&
                            drama.secondaryInfoList!.isNotEmpty)
                          _buildStatTag(drama.secondaryInfoList![0].content),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getRankColor(int rank) {
    switch (rank) {
      case 1:
        return const Color(0xFFFF7D27); // Orange
      case 2:
        return const Color(0xFF2DC3A6); // Teal
      case 3:
        return const Color(0xFF5E85F7); // Blue
      default:
        return const Color(0x99000000); // Overlay Black
    }
  }

  Widget _buildStatTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0), // Light Orange
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFE65100), // Dark Orange
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _XHSCard extends StatelessWidget {
  const _XHSCard({
    required this.drama,
    required this.apiClient,
    this.downloadService,
  });

  final Drama drama;
  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  Widget build(BuildContext context) {
    return TvTap(
      borderRadius: DeviceProfile.isTv ? 14 : 12,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DramaDetailPage(
              drama: drama,
              apiClient: apiClient,
              downloadService: downloadService,
            ),
          ),
        );
      },
      child: Container(
        padding: DeviceProfile.isTv ? const EdgeInsets.all(8) : EdgeInsets.zero,
        decoration: DeviceProfile.isTv
            ? BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE8EBF0)),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[200],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: drama.cover,
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) =>
                          Container(color: Colors.grey[200]),
                    ),
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          (drama.playCnt ?? 0) > 10000
                              ? '${((drama.playCnt ?? 0) / 10000).toInt()}万'
                              : '${drama.playCnt ?? 0}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    // 左上角徽标
                    if (drama.tagInfo != null && drama.tagInfo!.text.isNotEmpty)
                      _buildTopBadge(
                        drama.tagInfo!.text,
                        _parseColor(
                          drama.tagInfo!.bgColor.isNotEmpty
                              ? drama.tagInfo!.bgColor.first
                              : '',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              drama.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1D1D1F),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              drama.subTitle ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
            ),
          ],
        ),
      ),
    );
  }

  Color _parseColor(String colorStr) {
    if (colorStr.isEmpty) return const Color(0xFFFF2442);
    try {
      final hex = colorStr.replaceAll('#', '');
      if (hex.length == 6) {
        return Color(int.parse('0xFF$hex'));
      } else if (hex.length == 8) {
        return Color(int.parse('0x$hex'));
      }
    } catch (_) {}
    return const Color(0xFFFF2442);
  }

  Widget _buildTopBadge(String text, Color color) {
    return Positioned(
      top: 8,
      left: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.9), // 稍微透明一点更有质感
          borderRadius: const BorderRadius.all(
            Radius.circular(4),
          ), // 小红书风格倾向于圆角矩形
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
