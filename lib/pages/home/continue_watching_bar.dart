import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/playback_record.dart';
import '../../services/api_client.dart';
import '../../services/download_service.dart';
import '../../services/playback_history_store.dart';
import '../playback_record_launcher.dart';

/// 首页底部导航栏上方的“继续观看”提示条，展示播放历史里最新的一部。
///
/// 不常驻：每次启动只在首页出现一次，[displayDuration] 后自动收起；
/// 点关闭或点“继续观看”也会收起，本次启动内不再出现。
class ContinueWatchingBar extends StatefulWidget {
  const ContinueWatchingBar({
    super.key,
    required this.apiClient,
    this.downloadService,
    this.active = true,
    this.displayDuration = defaultDisplayDuration,
  });

  final ApiClient apiClient;
  final DownloadService? downloadService;

  /// 首页 tab 是否在前台。切到其他 tab 时先藏起来，倒计时照常进行。
  final bool active;

  final Duration displayDuration;

  static const Duration defaultDisplayDuration = Duration(seconds: 8);

  @override
  State<ContinueWatchingBar> createState() => _ContinueWatchingBarState();
}

class _ContinueWatchingBarState extends State<ContinueWatchingBar> {
  PlaybackRecord? _record;
  bool _dismissed = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _load();
    PlaybackHistoryStore.revision.addListener(_load);
  }

  @override
  void dispose() {
    PlaybackHistoryStore.revision.removeListener(_load);
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(ContinueWatchingBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _startTimerIfShown();
  }

  Future<void> _load() async {
    if (_dismissed) return;
    final records = await PlaybackHistoryStore.load();
    if (!mounted || _dismissed) return;
    setState(() {
      _record = records.where((r) => r.dramaId != 0).firstOrNull;
    });
    _startTimerIfShown();
  }

  /// 倒计时从提示条第一次真正露出时开始。
  void _startTimerIfShown() {
    if (_hideTimer != null || _dismissed) return;
    if (_record == null || !widget.active) return;
    _hideTimer = Timer(widget.displayDuration, _dismiss);
  }

  void _dismiss() {
    if (!mounted || _dismissed) return;
    _hideTimer?.cancel();
    setState(() => _dismissed = true);
  }

  void _continue() {
    final record = _record;
    if (record == null || _dismissed || !widget.active) return;
    _dismiss();
    openPlaybackRecord(
      context,
      record: record,
      apiClient: widget.apiClient,
      downloadService: widget.downloadService,
    );
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    final visible = record != null && widget.active && !_dismissed;
    return ExcludeFocus(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 0.4),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: record == null
                ? const SizedBox.shrink()
                : _BarContent(
                    record: record,
                    onContinue: _continue,
                    onClose: _dismiss,
                  ),
          ),
        ),
      ),
    );
  }
}

class _BarContent extends StatelessWidget {
  const _BarContent({
    required this.record,
    required this.onContinue,
    required this.onClose,
  });

  final PlaybackRecord record;
  final VoidCallback onContinue;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final episode = record.episodeNumber ?? record.episodeIndex + 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: const Color(0xE6222222),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onContinue,
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('continue-watching-close'),
                  onPressed: onClose,
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded,
                      size: 18, color: Color(0xB3FFFFFF)),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 28,
                    height: 38,
                    child: record.cover.isEmpty
                        ? const ColoredBox(color: Color(0xFF444444))
                        : CachedNetworkImage(
                            imageUrl: record.cover,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                const ColoredBox(color: Color(0xFF444444)),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      const TextSpan(text: '上次看到 '),
                      TextSpan(
                        text: record.dramaName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: ' 第$episode集'),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: FilledButton(
                    onPressed: onContinue,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF2442),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    child: const Text('继续观看'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
