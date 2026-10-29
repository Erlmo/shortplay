import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/twixive.dart';
import '../../services/api_client.dart';
import '../../services/liked_video_store.dart';
import '../../widgets/twixive_cards.dart';
import 'twixive_home_page.dart';
import '../player_page.dart';

class TwixiveList extends StatefulWidget {
  const TwixiveList(
      {super.key,
      required this.apiClient,
      this.feed = TwixiveFeed.home,
      this.user,
      this.likedOnly = false});

  final ApiClient apiClient;
  final TwixiveFeed feed;
  final TwixiveUser? user;
  final bool likedOnly;

  @override
  State<TwixiveList> createState() => _TwixiveListState();
}

class _TwixiveListState extends State<TwixiveList>
    with AutomaticKeepAliveClientMixin {
  static const _pageSize = 24;
  final _scroll = ScrollController();
  final List<TwixiveVideo> _videos = [];
  final List<TwixiveUser> _users = [];
  CancelToken? _cancel;
  int _request = 0;
  int _offset = 0;
  int _days = 1;
  String? _cursor;
  String? _error;
  bool _loading = false;
  bool _hasMore = true;
  TwixiveUser? _user;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _user = widget.user;
    if (widget.likedOnly) LikedVideoStore.revision.addListener(_onLikesChanged);
    _scroll.addListener(_onScroll);
    unawaited(_load(reset: true));
  }

  void _onLikesChanged() {
    unawaited(_load(reset: true));
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 600 &&
        !_loading &&
        _error == null &&
        _hasMore) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || !_hasMore)) return;
    _cancel?.cancel('切换或重新加载');
    final cancel = _cancel = CancelToken();
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _videos.clear();
        _users.clear();
        _offset = 0;
        _cursor = null;
        _hasMore = true;
      }
    });
    try {
      final TwixivePage result;
      if (widget.likedOnly) {
        final videos = await LikedVideoStore.load();
        result = TwixivePage(
            videos: videos, hasMore: false, nextOffset: videos.length);
      } else {
        result = await widget.apiClient.fetchTwixivePage(
          feed: widget.feed,
          days: _days,
          limit: _pageSize,
          offset: _offset,
          user: widget.user?.identifier,
          cursor: _cursor,
          cancelToken: cancel,
        );
      }
      if (!mounted || request != _request) return;
      setState(() {
        final ids = _videos.map((video) => video.id).toSet();
        final authors = _users.map((user) => user.identifier).toSet();
        final before = _videos.length + _users.length;
        _videos.addAll(result.videos.where((video) => ids.add(video.id)));
        _users
            .addAll(result.users.where((user) => authors.add(user.identifier)));
        _hasMore = result.hasMore && _videos.length + _users.length > before;
        if (widget.user != null && result.nextCursor == _cursor) {
          _hasMore = false;
        }
        _offset = result.nextOffset;
        _cursor = result.nextCursor;
        _user = result.user ?? _user;
      });
    } catch (error) {
      if (mounted &&
          request == _request &&
          !(error is DioException && CancelToken.isCancel(error))) {
        setState(
            () => _error = error is ApiException ? error.message : '加载失败，请重试');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    LikedVideoStore.revision.removeListener(_onLikesChanged);
    _cancel?.cancel('页面关闭');
    _scroll.dispose();
    super.dispose();
  }

  void _openUser(TwixiveUser user) {
    if (user.identifier.isEmpty) return;
    Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) =>
            TwixiveUserPage(apiClient: widget.apiClient, user: user)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      color: const Color(0xFFFF2442),
      onRefresh: () => _load(reset: true),
      child: LayoutBuilder(builder: (context, constraints) {
        final columns = (constraints.maxWidth / 190).floor().clamp(2, 6);
        return CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (_user != null)
              SliverToBoxAdapter(
                  child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: TwixiveUserCard(user: _user!))),
            if (widget.feed == TwixiveFeed.ranking && widget.user == null)
              SliverToBoxAdapter(
                  child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Wrap(spacing: 10, children: [
                  for (final days in [1, 3, 7])
                    ChoiceChip(
                        label: Text(days == 1 ? '24 小时' : '$days 日'),
                        selected: _days == days,
                        showCheckmark: false,
                        selectedColor: const Color(0xFFFFE9ED),
                        side: BorderSide.none,
                        onSelected: (_) {
                          if (_days == days) return;
                          setState(() => _days = days);
                          if (_scroll.hasClients) _scroll.jumpTo(0);
                          unawaited(_load(reset: true));
                        }),
                ]),
              )),
            if (_videos.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 16,
                      childAspectRatio: 0.64),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final video = _videos[index];
                    return TwixiveVideoCard(
                        video: video,
                        rank: widget.feed == TwixiveFeed.ranking
                            ? index + 1
                            : null,
                        onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                                builder: (_) => PlayerPage.direct(
                                    apiClient: widget.apiClient,
                                    url: video.url,
                                    video: video,
                                    title: video.author.label.isEmpty
                                        ? '视频播放'
                                        : video.author.label,
                                    cover: video.thumbnail))),
                        onAuthorTap: () => _openUser(video.author));
                  }, childCount: _videos.length),
                ),
              ),
            if (_users.isNotEmpty)
              SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  sliver: SliverList.separated(
                    itemCount: _users.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, index) => TwixiveUserCard(
                        user: _users[index],
                        rank: index + 1,
                        onTap: () => _openUser(_users[index])),
                  )),
            SliverToBoxAdapter(
                child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: Center(
                  child: _loading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : _error != null
                          ? Column(children: [
                              Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Color(0xFF777D87))),
                              const SizedBox(height: 8),
                              TextButton(
                                  onPressed: () => _load(
                                      reset: _videos.isEmpty && _users.isEmpty),
                                  child: const Text('重新加载'))
                            ])
                          : _videos.isEmpty && _users.isEmpty
                              ? Text(
                                  widget.likedOnly
                                      ? '还没有喜欢的视频，在播放页点爱心即可加入'
                                      : '暂无内容，下拉刷新试试',
                                  style: TextStyle(color: Color(0xFF90949B)))
                              : _hasMore
                                  ? TextButton(
                                      onPressed: _load,
                                      child: const Text('加载更多'))
                                  : const Text('已经到底了',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFFA0A4AD)))),
            )),
          ],
        );
      }),
    );
  }
}
