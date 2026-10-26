import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/drama.dart';
import '../../services/api_client.dart';
import '../../services/device_profile.dart';
import '../../services/download_service.dart';
import '../../widgets/tv_tap.dart';
import 'home_drama_card.dart';
import 'rank_list_item.dart';

// 通用的列表 Tab
class DramaListTab extends StatefulWidget {
  const DramaListTab({
    super.key,
    required this.apiClient,
    required this.fetchFunction,
    this.downloadService,
    this.enableFilters = false,
    this.useGridView = true,
    this.showRanking = false,
    this.header,
  });

  final ApiClient apiClient;
  final DownloadService? downloadService;
  final bool enableFilters;
  final bool useGridView;
  final bool showRanking;

  /// 列表上方的额外内容（如顶部提示），随列表一起滚动。
  final Widget? header;
  final Future<HomePageResult> Function(
    ApiClient client,
    int? offset,
    String? sessionId,
    String type,
  ) fetchFunction;

  @override
  State<DramaListTab> createState() => DramaListTabState();
}

class DramaListTabState extends State<DramaListTab>
    with AutomaticKeepAliveClientMixin {
  final List<Drama> _dramas = [];
  bool _isLoading = false;
  bool _hasMore = true;
  String? _sessionId;
  String? _loadError;
  int? _nextOffset;
  int _requestGeneration = 0;
  bool _initialPrefetchRunning = false;
  final Set<int> _loadedOffsets = {};
  static const _tvInitialItemTarget = 24;
  static const _tvInitialPageLimit = 6;
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
    _requestGeneration++;
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      if (!_isLoading &&
          !_initialPrefetchRunning &&
          _loadError == null &&
          _hasMore) {
        _loadMore();
      }
    }
  }

  Future<void> _loadData() async {
    final generation = ++_requestGeneration;
    _initialPrefetchRunning = true;
    setState(() {
      _dramas.clear();
      _loadedOffsets.clear();
      _sessionId = null;
      _nextOffset = null;
      _hasMore = true;
      _isLoading = false;
      _loadError = null;
    });

    var pageCount = 0;
    do {
      final loaded = await _fetchPage(generation);
      if (!mounted || generation != _requestGeneration) return;
      pageCount++;
      if (!loaded ||
          !DeviceProfile.isTv ||
          !_hasMore ||
          _dramas.length >= _tvInitialItemTarget ||
          pageCount >= _tvInitialPageLimit) {
        break;
      }
    } while (true);
    _initialPrefetchRunning = false;
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore || _initialPrefetchRunning) return;
    await _fetchPage(_requestGeneration);
  }

  Future<bool> _fetchPage(int generation) async {
    final offset = _nextOffset;
    final sessionId = _sessionId;
    final type = _currentType;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final result = await widget.fetchFunction(
        widget.apiClient,
        offset,
        sessionId,
        type,
      );
      if (!mounted || generation != _requestGeneration) return false;
      setState(() {
        if (DeviceProfile.isTv) {
          // 不把接口偶尔重复的同一作品计入电视首屏的补充目标。
          final ids = _dramas.map((drama) => drama.id).toSet();
          _dramas.addAll(result.list.where((drama) => ids.add(drama.id)));
        } else {
          _dramas.addAll(result.list);
        }
        _loadedOffsets.add(offset ?? result.offset);
        _sessionId = result.sessionId;
        _nextOffset = result.nextOffset;
        // 游标必须来自接口；重复游标不能重发，否则空页会不断请求。
        _hasMore = result.hasMore &&
            (!DeviceProfile.isTv ||
                !_loadedOffsets.contains(result.nextOffset));
        _isLoading = false;
      });
      return true;
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return false;
      setState(() {
        _isLoading = false;
        _loadError = e is ApiException ? e.message : '加载失败，请稍后重试';
      });
      return false;
    }
  }

  void _onFilterChanged(String displayFilter) {
    final newType = _filterMap[displayFilter]!;
    if (_currentType == newType) return;

    setState(() {
      _currentType = newType;
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
              : _dramas.isEmpty && _loadError != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      TextButton(onPressed: _loadData, child: const Text('重试')),
                    ]))
                  : RefreshIndicator(
                      onRefresh: _loadData,
                      color: const Color(0xFFFF2442),
                      child: CustomScrollView(
                        controller: _scrollController,
                        physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        slivers: [
                          if (widget.header != null)
                            SliverToBoxAdapter(child: widget.header),
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
                                      return HomeDramaCard(
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
                                      return RankListItem(
                                        drama: _dramas[index],
                                        apiClient: widget.apiClient,
                                        downloadService: widget.downloadService,
                                        rank: widget.showRanking
                                            ? index + 1
                                            : null,
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

    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Text(_loadError!, style: const TextStyle(color: Color(0xFF999999))),
            const SizedBox(height: 8),
            TvTap(
              borderRadius: 12,
              onTap: _loadMore,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Text('重试加载'),
              ),
            ),
          ],
        ),
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
