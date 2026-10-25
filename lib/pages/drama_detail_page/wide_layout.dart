part of '../drama_detail_page.dart';

/// 电视 / 桌面宽屏布局：左侧竖版海报，右侧信息 + 播放按钮 + 选集网格。
extension _DetailWideLayout on _DramaDetailPageState {
  Widget _buildHeaderInfo(BuildContext context) {
    final tags = <String>{
      if (drama.pureCategoryTags?.isNotEmpty ?? false)
        ...drama.pureCategoryTags!
            .split(RegExp(r'[,，·]'))
            .where((tag) => tag.trim().isNotEmpty)
            .map((tag) => tag.trim()),
      if (drama.status.isNotEmpty) drama.status,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(drama.name,
          style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF252A36),
              height: 1.35,
              letterSpacing: -.4)),
      if (drama.subTitle?.isNotEmpty ?? false) ...[
        const SizedBox(height: 6),
        Text(drama.subTitle!,
            style: const TextStyle(
                fontSize: 12, height: 1.5, color: Color(0xFF969CAB))),
      ],
      if (tags.isNotEmpty || (drama.score?.isNotEmpty ?? false)) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (drama.score?.isNotEmpty ?? false)
            _metadataBadge(drama.score!, icon: Icons.star_rounded, score: true),
          ...tags.take(4).map((tag) => _metadataBadge(tag)),
        ]),
      ],
      if (drama.recText?.isNotEmpty ?? false) ...[
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.local_fire_department_rounded,
              size: 14, color: Color(0xFFEF7786)),
          const SizedBox(width: 4),
          Expanded(
              child: Text(drama.recText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF969CAB)))),
        ]),
      ],
    ]);
  }

  Widget _metadataBadge(String label, {IconData? icon, bool score = false}) =>
      Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: score ? const Color(0xFFFFF4E5) : const Color(0xFFF5F6FA),
              borderRadius: BorderRadius.circular(6)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: const Color(0xFFCE8B35)),
              const SizedBox(width: 3),
            ],
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: score ? FontWeight.w600 : FontWeight.w400,
                    color: score
                        ? const Color(0xFFB97B2B)
                        : const Color(0xFF858B9A))),
          ]));

  Widget _buildActionButtons(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF2E55).withValues(alpha: .12),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
              gradient: const LinearGradient(
                colors: [Color(0xFFFF2E55), Color(0xFFFF5656)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: TvTap(
                ink: true,
                // 电视上进详情页默认选中“播放”，按 OK 直接开播
                autofocus: DeviceProfile.isTv,
                onTap: () => _startPlay(context),
                borderRadius: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '立即播放',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.downloadService != null && drama.isTheaterResource) ...[
          const SizedBox(width: 12),
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE8EAF0)),
            ),
            child: Material(
              color: Colors.transparent,
              child: TvTap(
                ink: true,
                onTap: _addingDownloads ? null : () => _downloadAll(context),
                borderRadius: 12,
                child: _addingDownloads
                    ? const Center(child: CupertinoActivityIndicator())
                    : const Icon(
                        Icons.download_outlined,
                        color: Color(0xFFFF2E55),
                        size: 26,
                      ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildIntroSection(BuildContext context) => drama.intro.isEmpty
      ? const SizedBox.shrink()
      : ExpandableSynopsis(
          key: ValueKey('synopsis-${drama.id}'), text: drama.intro);

  // ─── 电视 / 桌面宽屏布局 ───────────────────────────────────────────────
  // 左侧竖版海报，右侧信息 + 播放按钮 + 选集网格。全部内容一屏放下，
  // 方向键：播放按钮默认选中，按“下”进入选集，按返回键退出。
  Widget _buildWideLayout(BuildContext context) {
    final cover = drama.cover.isNotEmpty
        ? Image.network(
            drama.cover,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildGradientBg(),
          )
        : _buildGradientBg();

    if (DeviceProfile.isTv) {
      return TvDramaDetailView(
        drama: drama,
        cover: cover,
        onBack: () => Navigator.of(context).pop(),
        onPlay: () => _startPlay(context),
        onDownload: widget.downloadService != null && drama.isTheaterResource
            ? () => _downloadAll(context)
            : null,
        addingDownloads: _addingDownloads,
        episodes: _prefetchedEpisodes != null ? _buildWideEpisodeGrid() : null,
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 32, 48, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 3 / 4,
                child: Hero(
                  tag: 'drama_cover_${drama.id}',
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(40),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: cover,
                  ),
                ),
              ),
              const SizedBox(width: 40),
              Expanded(
                child: SingleChildScrollView(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeaderInfo(context),
                    if (drama.intro.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildIntroSection(context),
                    ],
                    const SizedBox(height: 20),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: _buildActionButtons(context),
                    ),
                    const SizedBox(height: 20),
                    if (_prefetchedEpisodes != null)
                      SizedBox(height: 260, child: _buildWideEpisodeGrid()),
                  ],
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWideEpisodeGrid({bool embedded = false}) {
    final seasonSelector = _buildSeasonSelector();
    final currentSeason =
        _seasons?.seasons.where((s) => s.id == drama.id).firstOrNull;
    final seasonDescription = currentSeason == null
        ? drama.subTitle ?? ''
        : '${_seasons!.seasons.length}季${currentSeason.episodeCount > 0 ? ' · 本季${currentSeason.episodeCount}集' : ''}';
    final episodeBody = FutureBuilder<TheaterEpisodesResult>(
      key: ValueKey(drama.id),
      future: _prefetchedEpisodes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
              child: TextButton(
                  onPressed: () => _refresh(_prefetchEpisodes),
                  child: const Text('选集加载失败，点击重试')));
        }
        if (!snapshot.hasData) {
          return const Center(child: CupertinoActivityIndicator());
        }
        final episodes = snapshot.data!.toEpisodes();
        if (episodes.isEmpty) return const Center(child: Text('暂无剧集'));
        return EpisodeSelector(
          key: ValueKey('episodes-${drama.id}'),
          episodes: episodes,
          activeIndex: 0,
          onSelect: (index) => _startPlay(context, episodeIndex: index),
          autofocusActive: false,
          softStyle: true,
          embedded: embedded,
          horizontalPadding: 0,
        );
      },
    );
    return Column(
      key: const ValueKey('season-episode-selector'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            const Text('选集',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF252A36))),
            const SizedBox(width: 12),
            if (seasonDescription.isNotEmpty)
              Expanded(
                  child: Text(seasonDescription,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF969CAB)))),
          ]),
        ),
        if (seasonSelector != null) ...[
          seasonSelector,
          const SizedBox(height: 6),
        ],
        if (embedded) episodeBody else Expanded(child: episodeBody),
      ],
    );
  }

  Widget _buildGradientBg() {
    return Container(
      decoration: const BoxDecoration(color: Color(0xFFE5E5EA)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_rounded, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              '暂无封面',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
