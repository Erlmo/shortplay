import 'package:flutter/material.dart';

import '../models/drama.dart';
import 'tv_tap.dart';
import 'expandable_synopsis.dart';

/// 电视详情页：信息与操作集中在上方，选集区独立占用下方空间。
class TvDramaDetailView extends StatelessWidget {
  const TvDramaDetailView({
    super.key,
    required this.drama,
    required this.cover,
    required this.onBack,
    required this.onPlay,
    this.onDownload,
    this.addingDownloads = false,
    this.episodes,
  });

  final Drama drama;
  final Widget cover;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback? onDownload;
  final bool addingDownloads;
  final Widget? episodes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 18, 32, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                TvTap(
                  onTap: onBack,
                  borderRadius: 12,
                  focusScale: 1,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(children: [
                      Icon(Icons.arrow_back_rounded,
                          size: 18, color: Color(0xFF424957)),
                      SizedBox(width: 7),
                      Text('返回',
                          style: TextStyle(
                              fontSize: 13, color: Color(0xFF424957))),
                    ]),
                  ),
                ),
                const Spacer(),
                const Text('剧集详情',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9299A6))),
              ]),
              const SizedBox(height: 16),
              Expanded(
                child: LayoutBuilder(builder: (context, constraints) {
                  final heroHeight = episodes == null
                      ? constraints.maxHeight.clamp(180.0, 300.0)
                      : (constraints.maxHeight * .46).clamp(170.0, 225.0);
                  final episodeHeight =
                      (constraints.maxHeight - heroHeight - 20)
                          .clamp(180.0, 320.0);
                  return SingleChildScrollView(
                      child: Column(children: [
                    SizedBox(
                      height: heroHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                      color: Colors.black.withAlpha(20),
                                      blurRadius: 20,
                                      offset: const Offset(0, 8),
                                    )
                                  ],
                                ),
                                child: cover,
                              ),
                            ),
                          ),
                          const SizedBox(width: 28),
                          Expanded(child: _buildInfo(context)),
                        ],
                      ),
                    ),
                    if (episodes != null) ...[
                      const SizedBox(height: 20),
                      SizedBox(
                          height: episodeHeight,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border:
                                  Border.all(color: const Color(0xFFEEF0F5)),
                            ),
                            child: episodes,
                          )),
                    ],
                  ]));
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfo(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
          child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(drama.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 24,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF242833))),
          if (drama.subTitle?.isNotEmpty ?? false) ...[
            const SizedBox(height: 7),
            Text(drama.subTitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF747B88))),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (drama.score?.isNotEmpty ?? false)
              _badge(drama.score!,
                  icon: Icons.star_rounded,
                  color: const Color(0xFFB77A26),
                  background: const Color(0xFFFFF0DC)),
            if (drama.pureCategoryTags?.isNotEmpty ?? false)
              _badge(drama.pureCategoryTags!),
            if (drama.status.isNotEmpty) _badge(drama.status),
            if (drama.recText?.isNotEmpty ?? false)
              _badge(drama.recText!,
                  icon: Icons.local_fire_department_outlined),
          ]),
          if (drama.intro.isNotEmpty) ...[
            const SizedBox(height: 12),
            ExpandableSynopsis(
                key: ValueKey('synopsis-${drama.id}'), text: drama.intro),
          ],
        ]),
      )),
      const SizedBox(height: 12),
      Row(children: [
        _action(
            label: '立即播放',
            icon: Icons.play_arrow_rounded,
            primary: true,
            onTap: onPlay),
        if (onDownload != null) ...[
          const SizedBox(width: 12),
          _action(
              label: addingDownloads ? '正在添加…' : '缓存全集',
              icon: Icons.download_rounded,
              onTap: addingDownloads ? null : onDownload),
        ],
      ]),
    ]);
  }

  Widget _action(
      {required String label,
      required IconData icon,
      required VoidCallback? onTap,
      bool primary = false}) {
    return TvTap(
      autofocus: primary,
      focusScale: 1,
      borderRadius: 13,
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: primary ? const Color(0xFFFF2442) : Colors.white,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
              color:
                  primary ? const Color(0xFFFF2442) : const Color(0xFFE1E5EC)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 21,
              color: primary ? Colors.white : const Color(0xFF424957)),
          const SizedBox(width: 7),
          Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: primary ? Colors.white : const Color(0xFF424957))),
        ]),
      ),
    );
  }

  Widget _badge(String label,
      {IconData? icon,
      Color color = const Color(0xFF747B88),
      Color background = const Color(0xFFE9ECF2)}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: background, borderRadius: BorderRadius.circular(7)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3)
        ],
        Text(label,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
