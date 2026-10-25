part of '../drama_detail_page.dart';

/// 手机竖屏布局：沉浸式封面、标题信息、紧凑选集条、底部操作栏。
extension _DetailPhoneLayout on _DramaDetailPageState {
  Widget _buildImmersiveHeader() {
    final suffix = RegExp(r'第[一二三四五六七八九十百零两0-9]+季$').firstMatch(drama.name);
    final title = suffix == null || suffix.start == 0
        ? drama.name
        : drama.name.substring(0, suffix.start).trim();
    final tags = <String>{
      ...(drama.pureCategoryTags ?? '').split(RegExp(r'[,，·]')),
      ...drama.tags,
    }.map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).take(3);
    final metadata = {
      if (drama.status.isNotEmpty) drama.status,
      if (drama.subTitle?.isNotEmpty ?? false) drama.subTitle!,
    }.join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 24,
                  height: 1.25,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.4,
                  color: Color(0xFF111827))),
        ),
        if (drama.score?.isNotEmpty ?? false) ...[
          const SizedBox(width: 10),
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF1F0),
              border: Border.all(color: const Color(0xFFFFE4E3)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.star_rounded, size: 14, color: detailAccent),
              const SizedBox(width: 2),
              Text(drama.score!,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: detailAccent)),
            ]),
          ),
        ],
      ]),
      if (metadata.isNotEmpty || tags.isNotEmpty) ...[
        const SizedBox(height: 9),
        Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (metadata.isNotEmpty)
                Text(metadata,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280))),
              ...tags.map((tag) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(tag,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF6B7280))),
                  )),
            ]),
      ],
    ]);
  }

  Future<void> _openAllEpisodes(List<Episode> episodes) async {
    final requestedId = drama.id;
    final season =
        _seasons?.seasons.where((s) => s.id == requestedId).firstOrNull;
    final index = await showDetailEpisodesSheet(
      context: context,
      title: drama.name,
      seasonLabel: season == null ? '' : '第${season.order}季 · ',
      episodes: episodes,
    );
    if (!mounted || requestedId != drama.id || index == null) return;
    _startPlay(context, episodeIndex: index);
  }

  Widget _buildCompactEpisodes() => FutureBuilder<TheaterEpisodesResult>(
        key: ValueKey('compact-episodes-${drama.id}'),
        future: _prefetchedEpisodes,
        builder: (context, snapshot) {
          final episodes = snapshot.data?.toEpisodes() ?? const <Episode>[];
          final seasonSelector = _buildSeasonSelector();
          return Column(
            key: const ValueKey('season-episode-selector'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('选集',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827))),
                if (episodes.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('全${episodes.length}集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9CA3AF)))),
                  TextButton(
                    key: const ValueKey('detail-show-all'),
                    onPressed: () => unawaited(_openAllEpisodes(episodes)),
                    style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF6B7280),
                        padding: EdgeInsets.zero),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('全部 ${episodes.length} 集',
                          style: const TextStyle(fontSize: 12)),
                      const Icon(Icons.chevron_right_rounded, size: 16),
                    ]),
                  ),
                ],
              ]),
              if (seasonSelector != null) ...[
                seasonSelector,
                const SizedBox(height: 6)
              ],
              if (snapshot.hasError)
                Center(
                    child: TextButton(
                        onPressed: () => _refresh(_prefetchEpisodes),
                        child: const Text('选集加载失败，点击重试')))
              else if (!snapshot.hasData)
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CupertinoActivityIndicator()))
              else if (episodes.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('暂无剧集',
                        style: TextStyle(color: Color(0xFF9CA3AF))))
              else
                DetailEpisodeStrip(
                  key: ValueKey('episodes-${drama.id}'),
                  episodes: episodes,
                  onSelect: (index) => _startPlay(context, episodeIndex: index),
                  onShowAll: () => unawaited(_openAllEpisodes(episodes)),
                ),
            ],
          );
        },
      );

  Widget _buildImmersiveActions(BuildContext context) => DetailActionBar(
        key: const ValueKey('detail-play-bar'),
        onPlay: () => _startPlay(context),
        onDownload: widget.downloadService != null && drama.isTheaterResource
            ? () => _downloadAll(context)
            : null,
        addingDownloads: _addingDownloads,
      );

  Widget _buildSliverAppBar(BuildContext context, Size size) {
    return SliverAppBar(
      // 比原封面加高约 30dp，留出更自然的渐隐空间。
      expandedHeight: (size.width * .82).clamp(240.0, 330.0) -
          MediaQuery.paddingOf(context).top,
      pinned: true,
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: TvTap(
        borderRadius: 24,
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .24),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: .25),
              width: 0.5,
            ),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white,
            size: 18,
          ),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: 'drama_cover_${drama.id}',
              child: drama.cover.isNotEmpty
                  ? Image.network(
                      drama.cover,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      errorBuilder: (_, __, ___) => _buildGradientBg(),
                    )
                  : _buildGradientBg(),
            ),
            // 在较长距离内逐渐增大白色透明度，避免封面底部出现突兀白带。
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 120,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00FFFFFF),
                      Color(0x0AFFFFFF),
                      Color(0x33FFFFFF),
                      Color(0x8CFFFFFF),
                      Color(0xE6FFFFFF),
                      Colors.white,
                    ],
                    stops: [0.0, 0.2, 0.46, 0.7, 0.9, 1.0],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
