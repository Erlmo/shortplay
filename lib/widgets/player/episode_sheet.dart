import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/episode.dart';
import '../../services/download_service.dart';
import '../episode_selector.dart';
import '../../services/device_profile.dart';
import '../tv_side_panel.dart';
import 'hg_episode_panel.dart';

Future<void> showPlayerEpisodeSheet({
  required BuildContext context,
  required bool isLandscapeFullScreen,
  required String dramaName,
  required List<Episode> episodes,
  required ValueListenable<int> episodeNotifier,
  required ValueChanged<int> onSelectEpisode,
  String cover = '',
  String intro = '',
  String status = '',
}) {
  // 手机、平板、桌面（macOS 等）：红果选集面板；宽窗口 / 横屏全屏用右侧侧栏。
  // 只有电视保留遥控器焦点版的侧边面板。
  if (!DeviceProfile.isTv) {
    final size = MediaQuery.of(context).size;
    return showHgEpisodePanel(
      context: context,
      landscape: isLandscapeFullScreen || size.width > size.height,
      dramaName: dramaName,
      cover: cover,
      intro: intro,
      status: status.isEmpty ? '共${episodes.length}集' : status,
      episodes: episodes,
      episodeNotifier: episodeNotifier,
      onSelectEpisode: onSelectEpisode,
    );
  }
  // 电视：右侧全高深色面板（遥控器焦点）
  if (useSidePanel(context) || isLandscapeFullScreen) {
    return showSidePanel<void>(
      context: context,
      color: _darkPanel,
      barrierColor: Colors.black.withAlpha(40),
      builder: (context) => _EpisodeSheetPanel(
        height: double.infinity,
        dramaName: dramaName,
        episodes: episodes,
        selector: _playbackSelector(
            context, episodes, episodeNotifier, onSelectEpisode,
            dark: true),
        titleVerticalPadding: 24,
        square: true,
      ),
    );
  }

  if (isLandscapeFullScreen) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (context) {
        final media = MediaQuery.of(context);
        return Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: _EpisodeSheetPanel(
              width: media.size.width * 0.7,
              height: media.size.height * 0.7,
              dramaName: dramaName,
              episodes: episodes,
              selector: _playbackSelector(
                  context, episodes, episodeNotifier, onSelectEpisode),
              titleVerticalPadding: 16,
            ),
          ),
        );
      },
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: false,
    builder: (context) {
      final media = MediaQuery.of(context);
      final bottomPadding =
          (media.viewPadding.bottom * 0.5).clamp(8.0, 18.0).toDouble();

      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: _EpisodeSheetPanel(
          height: media.size.height * 0.45 + bottomPadding,
          bottomPadding: bottomPadding,
          dramaName: dramaName,
          episodes: episodes,
          selector: _playbackSelector(
              context, episodes, episodeNotifier, onSelectEpisode),
          showHandle: true,
        ),
      );
    },
  );
}

// 电视侧边面板的深色底，与播放设置面板（TvPlayerSettingsPanel）一致
const _darkPanel = Color(0xFF141414);

class _EpisodeSheetPanel extends StatelessWidget {
  const _EpisodeSheetPanel({
    required this.height,
    required this.dramaName,
    required this.episodes,
    required this.selector,
    this.footer,
    this.subtitle,
    this.width,
    this.bottomPadding = 0,
    this.titleVerticalPadding = 12,
    this.showHandle = false,
    this.square = false,
  });

  final double? width;
  final double height;
  final double bottomPadding;
  final double titleVerticalPadding;
  final bool showHandle;

  /// 侧边面板里使用：深色、不要圆角和阴影
  final bool square;
  final String dramaName;
  final List<Episode> episodes;
  final Widget selector;
  final Widget? footer;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: square
          ? const BoxDecoration(color: _darkPanel)
          : BoxDecoration(
              color: Colors.white.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color:
                      Colors.black.withValues(alpha: width == null ? 0.1 : 0.2),
                  blurRadius: width == null ? 10 : 20,
                  offset:
                      width == null ? const Offset(0, -2) : const Offset(0, 10),
                ),
              ],
            ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: Column(
          children: [
            if (showHandle)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            _EpisodeSheetHeader(
              dark: square,
              dramaName: dramaName,
              episodeCount: episodes.length,
              verticalPadding: titleVerticalPadding,
              subtitle: subtitle,
            ),
            Expanded(child: selector),
            if (footer != null) footer!,
          ],
        ),
      ),
    );
  }
}

class _EpisodeSheetHeader extends StatelessWidget {
  const _EpisodeSheetHeader({
    required this.dramaName,
    required this.episodeCount,
    required this.verticalPadding,
    this.subtitle,
    this.dark = false,
  });

  final bool dark;
  final String dramaName;
  final int episodeCount;
  final double verticalPadding;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: verticalPadding),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dramaName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: dark ? Colors.white : const Color(0xFF1A1A1A),
                    fontSize: dark ? 22 : 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 4,
                      height: 4,
                      decoration: const BoxDecoration(
                        color: Color(0xFF4ADE80),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        subtitle ?? '更新至 $episodeCount 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              dark ? Colors.white54 : const Color(0xFF757575),
                          fontSize: dark ? 14 : 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (dark)
            const Text('按返回键关闭',
                style: TextStyle(color: Colors.white38, fontSize: 13))
          else
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => Navigator.pop(context),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.05),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Color(0xFF424242),
                    size: 18,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Widget _playbackSelector(BuildContext context, List<Episode> episodes,
    ValueListenable<int> notifier, ValueChanged<int> onSelect,
    {bool dark = false}) {
  return ValueListenableBuilder<int>(
    valueListenable: notifier,
    builder: (context, index, _) => EpisodeSelector(
      dark: dark,
      episodes: episodes,
      activeIndex: index,
      onSelect: (index) {
        Navigator.of(context).pop();
        onSelect(index);
      },
    ),
  );
}

Future<List<Episode>?> showPlayerDownloadSheet({
  required BuildContext context,
  required bool isLandscapeFullScreen,
  required String dramaId,
  required String dramaName,
  required List<Episode> episodes,
  required int currentEpisodeIndex,
  required DownloadService downloadService,
}) {
  Widget panel(BuildContext context) => _DownloadEpisodePanel(
        dramaId: dramaId,
        dramaName: dramaName,
        episodes: episodes,
        currentEpisodeIndex: currentEpisodeIndex,
        downloadService: downloadService,
        landscape: isLandscapeFullScreen,
      );
  if (isLandscapeFullScreen) {
    return showDialog<List<Episode>>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (context) => Center(child: panel(context)),
    );
  }
  return showModalBottomSheet<List<Episode>>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: panel,
  );
}

class _DownloadEpisodePanel extends StatefulWidget {
  const _DownloadEpisodePanel({
    required this.dramaId,
    required this.dramaName,
    required this.episodes,
    required this.currentEpisodeIndex,
    required this.downloadService,
    required this.landscape,
  });

  final String dramaId;
  final String dramaName;
  final List<Episode> episodes;
  final int currentEpisodeIndex;
  final DownloadService downloadService;
  final bool landscape;

  @override
  State<_DownloadEpisodePanel> createState() => _DownloadEpisodePanelState();
}

class _DownloadEpisodePanelState extends State<_DownloadEpisodePanel> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.downloadService,
      builder: (context, _) {
        final downloads =
            widget.downloadService.groups[widget.dramaId]?.episodes ?? [];
        final byNumber = {
          for (final download in downloads) download.episode.index: download
        };
        final disabled = <int, String>{};
        for (int i = 0; i < widget.episodes.length; i++) {
          final ep = widget.episodes[i];
          final download = byNumber[ep.index];
          if (download == null || download.episode.url != ep.url) continue;
          if (download.isPlayable) {
            disabled[i] = '已缓存';
          } else if (download.status == DownloadStatus.pending ||
              download.status == DownloadStatus.downloading) {
            disabled[i] = '下载中';
          }
        }
        final available = {
          for (int i = 0; i < widget.episodes.length; i++)
            if (!disabled.containsKey(i)) i
        };
        final selected = _selected.intersection(available);
        final allSelected =
            available.isNotEmpty && selected.length == available.length;
        final media = MediaQuery.of(context);
        return Material(
          color: Colors.transparent,
          child: _EpisodeSheetPanel(
            width: widget.landscape ? media.size.width * 0.7 : null,
            height: media.size.height * (widget.landscape ? 0.85 : 0.6),
            bottomPadding: widget.landscape ? 8 : media.viewPadding.bottom + 8,
            dramaName: widget.dramaName,
            episodes: widget.episodes,
            subtitle: '下载本地 · 请选择集数',
            showHandle: !widget.landscape,
            selector: EpisodeSelector(
              episodes: widget.episodes,
              activeIndex: widget.currentEpisodeIndex,
              selectedIndexes: selected,
              disabledLabels: disabled,
              onSelect: (index) => setState(() {
                if (!_selected.add(index)) _selected.remove(index);
              }),
            ),
            footer: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(children: [
                TextButton(
                  onPressed: available.isEmpty
                      ? null
                      : () => setState(() {
                            _selected.clear();
                            if (!allSelected) _selected.addAll(available);
                          }),
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          final indexes = selected.toList()..sort();
                          Navigator.of(context).pop(
                              indexes.map((i) => widget.episodes[i]).toList());
                        },
                  child: Text('下载（${selected.length} 集）'),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
