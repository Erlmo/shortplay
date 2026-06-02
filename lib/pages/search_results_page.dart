import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import 'drama_detail_page.dart';

class SearchResultsPage extends StatefulWidget {
  const SearchResultsPage({
    super.key,
    required this.keyword,
    required this.apiClient,
    this.downloadService,
  });
  final String keyword;
  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  State<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends State<SearchResultsPage> {
  List<Drama> _results = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hadError = false;
  bool _hasMore = true;
  int _offset = 0;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _fetch();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_loadingMore &&
        _hasMore &&
        !_loading) {
      _fetchMore();
    }
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _hadError = false;
      _offset = 0;
      _hasMore = true;
    });
    try {
      final result = await widget.apiClient.search(widget.keyword);
      if (mounted)
        setState(() {
          _results = result.dramas;
          _offset = result.dramas.length;
          _hasMore = result.hasMore;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _results = const [];
          _hadError = true;
        });
    } finally {
      if (mounted)
        setState(() {
          _loading = false;
        });
    }
  }

  Future<void> _fetchMore() async {
    setState(() {
      _loadingMore = true;
    });
    try {
      final result = await widget.apiClient.search(
        widget.keyword,
        offset: _offset,
      );
      if (mounted)
        setState(() {
          _results = [..._results, ...result.dramas];
          _offset += result.dramas.length;
          _hasMore = result.hasMore;
        });
    } catch (_) {
      // 加载更多失败静默处理
    } finally {
      if (mounted)
        setState(() {
          _loadingMore = false;
        });
    }
  }

  void _openDrama(Drama drama) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DramaDetailPage(
          drama: drama,
          apiClient: widget.apiClient,
          downloadService: widget.downloadService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F7),
      body: SafeArea(
        child: CustomScrollView(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            SliverAppBar(
              backgroundColor: const Color(0xFFF5F5F7),
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              pinned: true,
              centerTitle: true,
              leading: IconButton(
                icon: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 20,
                  color: Color(0xFF1D1D1F),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                widget.keyword,
                style: const TextStyle(
                  color: Color(0xFF1D1D1F),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF1D1D1F),
                  ),
                ),
              )
            else if (_results.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _buildEmpty())
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.65,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 16,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => _buildGridItem(_results[i]),
                    childCount: _results.length,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
            if (_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 24),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF1D1D1F),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, color: Colors.grey[300], size: 64),
          const SizedBox(height: 12),
          Text(
            '未找到相关内容',
            style: TextStyle(color: Colors.grey[500], fontSize: 15),
          ),
          if (_hadError) ...[
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _fetch,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1D1D1F),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '重试',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGridItem(Drama drama) {
    return GestureDetector(
      onTap: () => _openDrama(drama),
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
                  _LazyNetworkImage(
                    url: drama.cover,
                    placeholder: Center(
                      child: Icon(
                        Icons.movie_filter_rounded,
                        color: Colors.grey[300],
                        size: 32,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 12,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            drama.recText ?? '${(drama.id * 1234) % 9000}万',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            drama.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1D1D1F),
            ),
          ),
        ],
      ),
    );
  }
}

class _LazyNetworkImage extends StatelessWidget {
  const _LazyNetworkImage({required this.url, required this.placeholder});
  final String url;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) return placeholder;
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final cw = (constraints.maxWidth * dpr).round();
        final ch = (constraints.maxHeight * dpr).round();
        return Image.network(
          url,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          cacheWidth: cw > 0 ? cw : null,
          cacheHeight: ch > 0 ? ch : null,
          loadingBuilder: (_, child, progress) => progress == null
              ? child
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    placeholder,
                    const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ],
                ),
          frameBuilder: (_, child, frame, sync) => sync
              ? child
              : AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: child,
                ),
          errorBuilder: (_, __, ___) => placeholder,
        );
      },
    );
  }
}
