import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/device_profile.dart';
import '../tv_side_panel.dart';
import '../tv_tap.dart';
import 'tv_player_settings_panel.dart';

enum PlayerMenuAction { download, episodes }

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
    final result = await showPlayerMoreSheet(
      context: context,
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

/// 打开“播放设置”（倍速 / 清晰度 / 定时 / 弹幕 / 下载）。
/// 手机上是底部弹层；电视 / 桌面横屏是右侧侧边面板，[showEpisodes] 时
/// 顶部多一个“选集”入口（遥控器没有别的地方能点到选集按钮）。
Future<PlayerMenuAction?> showPlayerMoreSheet({
  required BuildContext context,
  required bool canDownload,
  required bool isOfflinePlayback,
  required bool sleepTimerActive,
  bool danmakuEnabled = false,
  double playbackSpeed = 1,
  String currentQuality = '',
  Future<List<String>> Function()? loadQualities,
  VoidCallback? onToggleDanmaku,
  ValueChanged<double>? onSpeedChanged,
  ValueChanged<String>? onQualityChanged,
  ValueChanged<Duration?>? onSleepDurationChanged,
  int? sleepTimerMinutes,
  bool showEpisodes = false,
  bool forceSidePanel = false,
  ValueChanged<double>? onSheetLayout,
}) {
  // 手机、平板、桌面：红果“更多”面板（竖屏底部弹出；横屏全屏或宽窗口右侧 390dp 侧栏）。
  // 只有电视保留遥控器焦点版的设置面板。
  if (!DeviceProfile.isTv) {
    final size = MediaQuery.of(context).size;
    final side = forceSidePanel || size.width > size.height;
    Widget hg(BuildContext context, bool landscape) => _HgMoreSheet(
          landscape: landscape,
          canDownload: canDownload,
          isOfflinePlayback: isOfflinePlayback,
          danmakuEnabled: danmakuEnabled,
          playbackSpeed: playbackSpeed,
          currentQuality: currentQuality,
          loadQualities: loadQualities,
          onToggleDanmaku: onToggleDanmaku,
          onSpeedChanged: onSpeedChanged,
          onQualityChanged: onQualityChanged,
          onSleepDurationChanged: onSleepDurationChanged,
          sleepTimerMinutes: sleepTimerActive ? sleepTimerMinutes : null,
          showEpisodes: showEpisodes,
          onLayout: landscape ? null : onSheetLayout,
          onSelected: (value) => Navigator.of(context).pop(value),
        );
    if (side) {
      return showGeneralDialog<PlayerMenuAction>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭',
        barrierColor: Colors.black.withAlpha(40),
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, __) {
          final size = MediaQuery.of(context).size;
          return Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: math.min(size.width, 390),
              height: size.height,
              child: hg(context, true),
            ),
          );
        },
        transitionBuilder: (context, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );
    }
    return showModalBottomSheet<PlayerMenuAction>(
      context: context,
      backgroundColor: Colors.transparent,
      // 画面缩到面板上方，遮罩透明
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: false,
      builder: (context) => hg(context, false),
    );
  }
  final side = forceSidePanel || useSidePanel(context);
  Widget sheet(BuildContext context) => _PlayerMoreSheet(
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
        showEpisodes: showEpisodes,
        sidePanel: side,
        onSelected: (value) => Navigator.of(context).pop(value),
      );
  if (side) {
    return showSidePanel<PlayerMenuAction>(
      context: context,
      widthFraction: 0.36,
      minWidth: 420,
      color: panelBackground,
      // 遮罩很淡：调倍速 / 清晰度时能直接看到画面变化
      barrierColor: Colors.black.withAlpha(40),
      builder: (context) => TvPlayerSettingsPanel(
        canDownload: canDownload,
        isOfflinePlayback: isOfflinePlayback,
        danmakuEnabled: danmakuEnabled,
        playbackSpeed: playbackSpeed,
        currentQuality: currentQuality,
        loadQualities: loadQualities,
        onToggleDanmaku: onToggleDanmaku,
        onSpeedChanged: onSpeedChanged,
        onQualityChanged: onQualityChanged,
        onSleepDurationChanged: onSleepDurationChanged,
        sleepTimerMinutes: sleepTimerActive ? sleepTimerMinutes : null,
        showEpisodes: showEpisodes,
        onSelected: (value) => Navigator.of(context).pop(value),
      ),
    );
  }
  return showModalBottomSheet<PlayerMenuAction>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.48),
    isScrollControlled: true,
    useSafeArea: true,
    builder: sheet,
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
    this.showEpisodes = false,
    this.sidePanel = false,
  });

  final bool canDownload, isOfflinePlayback, sleepTimerActive, danmakuEnabled;
  final bool showEpisodes, sidePanel;
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
        borderRadius: widget.sidePanel
            ? null
            : const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              widget.sidePanel ? 28 : 20,
              widget.sidePanel ? 24 : 10,
              widget.sidePanel ? 28 : 20,
              16 + MediaQuery.of(context).viewPadding.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (!widget.sidePanel) _Handle(),
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
              if (widget.showEpisodes)
                _ActionRow(
                    icon: CupertinoIcons.square_grid_2x2,
                    title: '选集',
                    autofocus: true,
                    onTap: () => widget.onSelected(PlayerMenuAction.episodes)),
              _SettingRow(
                  icon: CupertinoIcons.speedometer,
                  title: '倍速',
                  child: _ChoiceStrip<double>(
                      values: const [0.75, 1, 1.25, 1.5, 2, 3],
                      selected: speed,
                      autofocusSelected: !widget.showEpisodes,
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
              _ActionRow(
                  icon: CupertinoIcons.chat_bubble_text,
                  title: '弹幕',
                  // 整行可点（遥控器选中这一行按 OK 即可切换）
                  onTap: widget.onToggleDanmaku == null
                      ? null
                      : () {
                          setState(() => danmaku = !danmaku);
                          widget.onToggleDanmaku!();
                        },
                  trailing: ExcludeFocus(
                      child: Switch(
                          value: danmaku,
                          onChanged: widget.onToggleDanmaku == null
                              ? null
                              : (_) {
                                  setState(() => danmaku = !danmaku);
                                  widget.onToggleDanmaku!();
                                }))),
              _ActionRow(
                  icon: CupertinoIcons.arrow_down_to_line,
                  title: widget.isOfflinePlayback ? '已下载本地' : '下载本地',
                  enabled: widget.canDownload,
                  onTap: widget.canDownload
                      ? () => widget.onSelected(PlayerMenuAction.download)
                      : null),
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
              // 随字号缩放（电视面板字号放大后“清晰度”不换行）
              width: MediaQuery.textScalerOf(context).scale(48),
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
      required this.onChanged,
      this.autofocusSelected = false});
  final bool autofocusSelected;
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
                child: TvTap(
              borderRadius: 7,
              focusScale: 1.08,
              autofocus: autofocusSelected && value == selected,
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
      this.enabled = true,
      this.autofocus = false});
  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => TvTap(
        ink: true,
        focusScale: 1.0,
        autofocus: autofocus,
        onTap: enabled ? onTap : null,
        borderRadius: 10,
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

// ─── 播放设置面板（手机 / 平板 / 桌面）──────────────────────────────────
// 一行一个设置：左边名称，右边一条连续的分段轨道，选中块带滑动动画。
// 顶部两个大开关：弹幕、离线缓存。竖屏从底部弹出（画面缩到上方），
// 横屏 / 宽窗口从右侧 390 宽侧栏滑出。
const _pnBg = Color(0xFF1B1B1F); // 面板底
const _pnLine = Color(0x14FFFFFF); // 发丝线
const _pnText = Color(0xFFEDEDF0); // 主文字
const _pnMuted = Color(0xFF8E8E95); // 次要文字
const _pnAccent = Color(0xFFFF2442); // 只用于“已开启”的开关

class _HgMoreSheet extends StatefulWidget {
  const _HgMoreSheet({
    required this.landscape,
    required this.canDownload,
    required this.isOfflinePlayback,
    required this.danmakuEnabled,
    required this.playbackSpeed,
    required this.currentQuality,
    required this.onSelected,
    this.loadQualities,
    this.onToggleDanmaku,
    this.onSpeedChanged,
    this.onQualityChanged,
    this.onSleepDurationChanged,
    this.sleepTimerMinutes,
    this.showEpisodes = false,
    this.onLayout,
  });

  final bool landscape, canDownload, isOfflinePlayback, danmakuEnabled;
  final bool showEpisodes;
  final double playbackSpeed;
  final String currentQuality;
  final Future<List<String>> Function()? loadQualities;
  final ValueChanged<PlayerMenuAction> onSelected;
  final VoidCallback? onToggleDanmaku;
  final ValueChanged<double>? onSpeedChanged;
  final ValueChanged<String>? onQualityChanged;
  final ValueChanged<Duration?>? onSleepDurationChanged;
  final int? sleepTimerMinutes;

  /// 竖屏面板排版后的高度（含底部安全区），播放页据此把画面缩到面板上方
  final ValueChanged<double>? onLayout;

  @override
  State<_HgMoreSheet> createState() => _HgMoreSheetState();
}

class _HgMoreSheetState extends State<_HgMoreSheet> {
  late double _speed = widget.playbackSpeed;
  late String _quality = widget.currentQuality;
  late bool _danmaku = widget.danmakuEnabled;
  late int? _timer = widget.sleepTimerMinutes;
  List<String> _qualities = const [];
  final _sheetKey = GlobalKey();
  double _reported = 0;

  @override
  void initState() {
    super.initState();
    final loader = widget.loadQualities;
    if (loader != null) {
      loader().then((v) {
        if (mounted) setState(() => _qualities = v.reversed.toList());
      }, onError: (_) {});
    }
  }

  void _reportHeight() {
    if (widget.onLayout == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final h = box.size.height;
      if ((h - _reported).abs() < 1) return;
      _reported = h;
      widget.onLayout!(h);
    });
  }

  void _toggleDanmaku() {
    if (widget.onToggleDanmaku == null) return;
    setState(() => _danmaku = !_danmaku);
    widget.onToggleDanmaku!();
  }

  String _speedLabel(double v) =>
      v == v.roundToDouble() ? '${v.toStringAsFixed(1)}x' : '${v}x';

  String _timerLabel(int? v) => v == null ? '关闭' : '$v分钟';

  @override
  Widget build(BuildContext context) {
    _reportHeight();
    final media = MediaQuery.of(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 标题行
        SizedBox(
          height: 44,
          child: Row(children: [
            const Expanded(
              child: Text('播放设置',
                  style: TextStyle(
                      color: _pnText,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            Semantics(
              button: true,
              label: '关闭',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: const BoxDecoration(
                          color: Color(0x14FFFFFF), shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded,
                          size: 15, color: Color(0xFF9A9AA0)),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        // 开关 / 入口：图标 + 名称 + 右侧控件，不加底色
        _PanelRow(
          icon: Icons.subtitles_outlined,
          title: '弹幕',
          onTap: widget.onToggleDanmaku == null ? null : _toggleDanmaku,
          trailing: _PanelSwitch(on: _danmaku),
          semanticsValue: _danmaku ? '已开启' : '已关闭',
        ),
        _PanelRow(
          icon: Icons.file_download_outlined,
          title: '离线缓存',
          onTap: widget.canDownload
              ? () => widget.onSelected(PlayerMenuAction.download)
              : null,
          // 点一下就缓存全集，没有下一级，所以右边不放“选择集数”和箭头
          value: widget.isOfflinePlayback
              ? '本地播放中'
              : widget.canDownload
                  ? null
                  : '暂不可用',
        ),
        if (widget.showEpisodes)
          _PanelRow(
            icon: Icons.format_list_bulleted_rounded,
            title: '选集',
            onTap: () => widget.onSelected(PlayerMenuAction.episodes),
            chevron: true,
          ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Divider(height: 0.5, thickness: 0.5, color: _pnLine),
        ),
        _PanelTextScale<double>(
          label: '倍速',
          values: const [0.75, 1.0, 1.25, 1.5, 2.0, 3.0],
          selected: _speed,
          display: _speedLabel,
          onChanged: widget.onSpeedChanged == null
              ? null
              : (v) {
                  setState(() => _speed = v);
                  widget.onSpeedChanged!(v);
                },
        ),
        if (_qualities.isNotEmpty)
          _PanelTextScale<String>(
            label: '清晰度',
            values: _qualities,
            selected: _quality,
            display: (v) => v.toUpperCase(),
            onChanged: widget.onQualityChanged == null
                ? null
                : (v) {
                    setState(() => _quality = v);
                    widget.onQualityChanged!(v);
                  },
          ),
        _PanelTextScale<int?>(
          label: '定时关闭',
          values: const [null, 15, 30, 60, 90],
          selected: _timer,
          display: _timerLabel,
          onChanged: widget.onSleepDurationChanged == null
              ? null
              : (v) {
                  setState(() => _timer = v);
                  widget.onSleepDurationChanged!(
                      v == null ? Duration.zero : Duration(minutes: v));
                },
        ),
      ],
    );

    if (widget.landscape) {
      return Material(
        color: _pnBg,
        child: SafeArea(
          left: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: content,
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.72),
      child: Container(
        key: _sheetKey,
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(
          color: _pnBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: _pnLine)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            padding:
                EdgeInsets.fromLTRB(20, 8, 20, 22 + media.viewPadding.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: const Color(0x29FFFFFF),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              content,
            ]),
          ),
        ),
      ),
    );
  }
}

/// 一行入口：图标 + 名称 + 右侧（值 / 箭头 / 开关），不加底色
class _PanelRow extends StatelessWidget {
  const _PanelRow({
    required this.icon,
    required this.title,
    this.onTap,
    this.value,
    this.trailing,
    this.chevron = false,
    this.semanticsValue,
  });
  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final String? value;
  final Widget? trailing;
  final bool chevron;
  final String? semanticsValue;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: title,
      value: semanticsValue ?? value,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 50),
            child: Row(children: [
              Icon(icon, size: 20, color: _pnText),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: const TextStyle(color: _pnText, fontSize: 15)),
              ),
              if (value != null)
                Text(value!,
                    style: const TextStyle(color: _pnMuted, fontSize: 13.5)),
              if (chevron)
                const Padding(
                  padding: EdgeInsets.only(left: 2),
                  child: Icon(Icons.chevron_right_rounded,
                      size: 18, color: Color(0xFF6E6E75)),
                ),
              if (trailing != null) trailing!,
            ]),
          ),
        ),
      ),
    );
  }
}

/// 小开关：开启时红色轨道，圆点带过渡动画
class _PanelSwitch extends StatelessWidget {
  const _PanelSwitch({required this.on});
  final bool on;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 36,
        height: 21,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: on ? _pnAccent : const Color(0xFF3A3A40),
          borderRadius: BorderRadius.circular(10.5),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 17,
            height: 17,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      );
}

/// 一项设置：小标题 + 一排文字刻度。
/// 选中项白色加粗，下方一个红色小圆点；其余是灰色文字，没有底色和边框。
/// 选项 ≥5 个时两端对齐铺满一行，少的时候从左往右排。
class _PanelTextScale<T> extends StatelessWidget {
  const _PanelTextScale({
    required this.label,
    required this.values,
    required this.selected,
    required this.display,
    required this.onChanged,
  });
  final String label;
  final List<T> values;
  final T selected;
  final String Function(T) display;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final spread = values.length >= 5;
    Widget item(T v) {
      final sel = v == selected;
      return Semantics(
        button: true,
        selected: sel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onChanged == null ? null : () => onChanged!(v),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                display(v),
                style: TextStyle(
                  color: sel ? Colors.white : _pnMuted,
                  fontSize: 14,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 5),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: sel ? 1 : 0,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                      color: _pnAccent, shape: BoxShape.circle),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label,
              style: const TextStyle(color: _pnMuted, fontSize: 13)),
          const SizedBox(height: 6),
          if (spread)
            // Flexible + scaleDown：窄屏 / 大字号时整排等比缩小，不会溢出
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final v in values)
                  Flexible(
                    child: FittedBox(fit: BoxFit.scaleDown, child: item(v)),
                  ),
              ],
            )
          else
            Wrap(
              spacing: 26,
              children: [for (final v in values) item(v)],
            ),
        ],
      ),
    );
  }
}
