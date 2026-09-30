import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

enum PlayerMenuAction { download }

class PlayerMoreMenu extends StatelessWidget {
  const PlayerMoreMenu({
    super.key,
    required this.canDownload,
    required this.isOfflinePlayback,
    required this.sleepTimerActive,
    required this.onOpened,
    required this.onClosed,
    required this.onSelected,
    required this.child,
    this.danmakuEnabled = false,
    this.playbackSpeed = 1,
    this.currentQuality = '',
    this.loadQualities,
    this.onToggleDanmaku,
    this.onSpeedChanged,
    this.onQualityChanged,
    this.onSleepDurationChanged,
    this.sleepTimerMinutes,
  });

  final bool canDownload, isOfflinePlayback, sleepTimerActive, danmakuEnabled;
  final double playbackSpeed;
  final String currentQuality;
  final Future<List<String>> Function()? loadQualities;
  final VoidCallback onOpened, onClosed;
  final ValueChanged<PlayerMenuAction> onSelected;
  final Widget child;
  final VoidCallback? onToggleDanmaku;
  final ValueChanged<double>? onSpeedChanged;
  final ValueChanged<String>? onQualityChanged;
  final ValueChanged<Duration?>? onSleepDurationChanged;
  final int? sleepTimerMinutes;

  Future<void> _open(BuildContext context) async {
    onOpened();
    final result = await showModalBottomSheet<PlayerMenuAction>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.48),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _PlayerMoreSheet(
        canDownload: canDownload,
        isOfflinePlayback: isOfflinePlayback,
        sleepTimerActive: sleepTimerActive,
        danmakuEnabled: danmakuEnabled,
        playbackSpeed: playbackSpeed,
        currentQuality: currentQuality,
        loadQualities: loadQualities,
        onToggleDanmaku: onToggleDanmaku,
        onSpeedChanged: onSpeedChanged,
        onQualityChanged: onQualityChanged,
        onSleepDurationChanged: onSleepDurationChanged,
        sleepTimerMinutes: sleepTimerMinutes,
        onSelected: (value) => Navigator.of(context).pop(value),
      ),
    );
    onClosed();
    if (result != null) onSelected(result);
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: '更多功能',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(context),
          child: child,
        ),
      );
}

class _PlayerMoreSheet extends StatefulWidget {
  const _PlayerMoreSheet({
    required this.canDownload,
    required this.isOfflinePlayback,
    required this.sleepTimerActive,
    required this.danmakuEnabled,
    required this.playbackSpeed,
    required this.currentQuality,
    this.loadQualities,
    required this.onSelected,
    this.onToggleDanmaku,
    this.onSpeedChanged,
    this.onQualityChanged,
    this.onSleepDurationChanged,
    this.sleepTimerMinutes,
  });

  final bool canDownload, isOfflinePlayback, sleepTimerActive, danmakuEnabled;
  final double playbackSpeed;
  final String currentQuality;
  final Future<List<String>> Function()? loadQualities;
  final ValueChanged<PlayerMenuAction> onSelected;
  final VoidCallback? onToggleDanmaku;
  final ValueChanged<double>? onSpeedChanged;
  final ValueChanged<String>? onQualityChanged;
  final ValueChanged<Duration?>? onSleepDurationChanged;
  final int? sleepTimerMinutes;

  @override
  State<_PlayerMoreSheet> createState() => _PlayerMoreSheetState();
}

class _PlayerMoreSheetState extends State<_PlayerMoreSheet> {
  late double speed;
  late String quality;
  late bool danmaku;
  int? timerMinutes;
  List<String> qualities = const [];
  bool loadingQualities = false;
  bool qualityLoadFailed = false;

  Future<void> _loadQualities() async {
    final loader = widget.loadQualities;
    if (loader == null) return;
    setState(() {
      loadingQualities = true;
      qualityLoadFailed = false;
    });
    try {
      final values = await loader();
      if (!mounted) return;
      setState(() => qualities = values);
    } catch (_) {
      if (mounted) setState(() => qualityLoadFailed = true);
    } finally {
      if (mounted) setState(() => loadingQualities = false);
    }
  }

  @override
  void initState() {
    super.initState();
    speed = widget.playbackSpeed;
    quality = widget.currentQuality;
    danmaku = widget.danmakuEnabled;
    timerMinutes = widget.sleepTimerActive ? widget.sleepTimerMinutes : null;
    unawaited(_loadQualities());
  }

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white.withValues(alpha: 0.97),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 10, 20, 16 + MediaQuery.of(context).viewPadding.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _Handle(),
              const SizedBox(height: 14),
              Row(children: [
                const Expanded(
                    child: Text('播放设置',
                        style: TextStyle(
                            color: Color(0xFF1A1A1A),
                            fontSize: 18,
                            fontWeight: FontWeight.w800))),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded,
                        color: Color(0xFF424242))),
              ]),
              _SettingRow(
                  icon: CupertinoIcons.speedometer,
                  title: '倍速',
                  child: _ChoiceStrip<double>(
                      values: const [0.75, 1, 1.25, 1.5, 2, 3],
                      selected: speed,
                      label: (v) => '${v}x',
                      onChanged: (value) {
                        setState(() => speed = value);
                        widget.onSpeedChanged?.call(value);
                      })),
              _SettingRow(
                  icon: CupertinoIcons.tv,
                  title: '清晰度',
                  child: loadingQualities
                      ? const Text('加载中…',
                          style:
                              TextStyle(color: Color(0xFF8A8F98), fontSize: 12))
                      : qualityLoadFailed
                          ? TextButton(
                              onPressed: _loadQualities,
                              child: const Text('加载失败，点击重试'))
                          : qualities.isEmpty
                              ? Text(
                                  widget.isOfflinePlayback ? '本地画质' : '暂无可选画质',
                                  style: const TextStyle(
                                      color: Color(0xFF8A8F98), fontSize: 12))
                              : _ChoiceStrip<String>(
                                  values: qualities,
                                  selected: quality,
                                  label: (v) => v.toUpperCase(),
                                  onChanged: (value) {
                                    setState(() => quality = value);
                                    widget.onQualityChanged?.call(value);
                                  })),
              _ActionRow(
                  icon: CupertinoIcons.chat_bubble_text,
                  title: '弹幕',
                  trailing: Switch(
                      value: danmaku,
                      onChanged: widget.onToggleDanmaku == null
                          ? null
                          : (_) {
                              setState(() => danmaku = !danmaku);
                              widget.onToggleDanmaku!();
                            })),
              _ActionRow(
                  icon: CupertinoIcons.arrow_down_to_line,
                  title: widget.isOfflinePlayback ? '已下载本地' : '下载本地',
                  enabled: widget.canDownload,
                  onTap: widget.canDownload
                      ? () => widget.onSelected(PlayerMenuAction.download)
                      : null),
              _SettingRow(
                icon: CupertinoIcons.timer,
                title: '定时',
                child: _ChoiceStrip<int?>(
                  values: const [15, 30, 60, 90, 120, null],
                  selected: timerMinutes,
                  label: (value) => value == null ? '关闭' : '$value分',
                  onChanged: (value) {
                    setState(() => timerMinutes = value);
                    widget.onSleepDurationChanged?.call(value == null
                        ? Duration.zero
                        : Duration(minutes: value));
                  },
                ),
              ),
            ]),
          ),
        ),
      );
}

class _Handle extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(2))),
      );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow(
      {required this.icon, required this.title, required this.child});
  final IconData icon;
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          _SettingsIcon(icon: icon),
          const SizedBox(width: 8),
          SizedBox(
              width: 48,
              child: Text(title,
                  style: const TextStyle(
                      color: Color(0xFF1A1A1A),
                      fontSize: 14,
                      fontWeight: FontWeight.w600))),
          const SizedBox(width: 8),
          Expanded(child: child),
        ]),
      );
}

class _ChoiceStrip<T> extends StatelessWidget {
  const _ChoiceStrip(
      {required this.values,
      required this.selected,
      required this.label,
      required this.onChanged});
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T>? onChanged;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(9)),
        child: Wrap(spacing: 2, runSpacing: 2, children: [
          for (final value in values)
            SizedBox(
                child: GestureDetector(
              onTap: onChanged == null ? null : () => onChanged!(value),
              child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 7),
                  decoration: BoxDecoration(
                      color:
                          value == selected ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                      boxShadow: value == selected
                          ? [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 4)
                            ]
                          : null),
                  child: Text(label(value),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: value == selected
                              ? Color(0xFF1A1A1A)
                              : Color(0xFF8A8F98),
                          fontSize: 10,
                          fontWeight: value == selected
                              ? FontWeight.w700
                              : FontWeight.w500))),
            ))
        ]),
      );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow(
      {required this.icon,
      required this.title,
      this.trailing,
      this.onTap,
      this.enabled = true});
  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            _SettingsIcon(icon: icon, enabled: enabled),
            const SizedBox(width: 8),
            Expanded(
                child: Text(title,
                    style: TextStyle(
                        color: enabled ? Color(0xFF1A1A1A) : Color(0xFF9CA0A8),
                        fontSize: 15,
                        fontWeight: FontWeight.w600))),
            if (trailing != null)
              trailing!
            else
              const Icon(Icons.chevron_right_rounded,
                  color: Color(0xFF9CA0A8), size: 20),
          ]),
        ),
      );
}

class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon({required this.icon, this.enabled = true});
  final IconData icon;
  final bool enabled;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 30,
        height: 30,
        child: Center(
            child: Icon(icon,
                size: 21,
                color: enabled
                    ? const Color(0xFF424242)
                    : const Color(0xFFB9BCC2))),
      );
}
