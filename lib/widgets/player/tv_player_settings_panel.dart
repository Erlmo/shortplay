import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'player_more_menu.dart' show PlayerMenuAction;

// 电视 / 桌面横屏的播放设置面板（手机仍用底部弹层 _PlayerMoreSheet）。
//
// 设计：深色面板压在视频右侧（遮罩很淡，左侧画面仍可见）；每项是“小标题 + 一排大号
// 选项”；当前值填品牌红；遥控器焦点统一为白底黑字 + 轻微放大（电视上最
// 醒目、也最常见的焦点样式），不再用红色描边。

const _brand = Color(0xFFFF2442);
const panelBackground = Color(0xFF141414);

class TvPlayerSettingsPanel extends StatefulWidget {
  const TvPlayerSettingsPanel({
    super.key,
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
  });

  final bool canDownload, isOfflinePlayback, danmakuEnabled, showEpisodes;
  final double playbackSpeed;
  final String currentQuality;
  final int? sleepTimerMinutes;
  final Future<List<String>> Function()? loadQualities;
  final ValueChanged<PlayerMenuAction> onSelected;
  final VoidCallback? onToggleDanmaku;
  final ValueChanged<double>? onSpeedChanged;
  final ValueChanged<String>? onQualityChanged;
  final ValueChanged<Duration?>? onSleepDurationChanged;

  @override
  State<TvPlayerSettingsPanel> createState() => _TvPlayerSettingsPanelState();
}

class _TvPlayerSettingsPanelState extends State<TvPlayerSettingsPanel> {
  late double _speed = widget.playbackSpeed;
  late String _quality = widget.currentQuality;
  late bool _danmaku = widget.danmakuEnabled;
  late int? _timer = widget.sleepTimerMinutes;
  List<String> _qualities = const [];
  bool _loadingQualities = false;
  bool _qualityFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadQualities());
  }

  Future<void> _loadQualities() async {
    final loader = widget.loadQualities;
    if (loader == null) return;
    setState(() {
      _loadingQualities = true;
      _qualityFailed = false;
    });
    try {
      final values = await loader();
      if (mounted) setState(() => _qualities = values);
    } catch (_) {
      if (mounted) setState(() => _qualityFailed = true);
    } finally {
      if (mounted) setState(() => _loadingQualities = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(36, 40, 36, 28),
        children: [
          const Text(
            '播放设置',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 24),
          if (widget.showEpisodes)
            _TvTile(
              icon: CupertinoIcons.square_grid_2x2,
              title: '选集',
              autofocus: true,
              onTap: () => widget.onSelected(PlayerMenuAction.episodes),
            ),
          _section(
            '倍速',
            [
              for (final v in const [0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
                _TvChip(
                  label: v == 1.0 ? '正常' : '${v}x',
                  selected: v == _speed,
                  autofocus: !widget.showEpisodes && v == _speed,
                  onTap: widget.onSpeedChanged == null
                      ? null
                      : () {
                          setState(() => _speed = v);
                          widget.onSpeedChanged!(v);
                        },
                ),
            ],
          ),
          _section('清晰度', _qualityChips()),
          _section(
            '定时关闭',
            [
              for (final v in const <int?>[null, 15, 30, 60, 90, 120])
                _TvChip(
                  label: v == null ? '不开启' : '$v 分钟',
                  selected: v == _timer,
                  onTap: widget.onSleepDurationChanged == null
                      ? null
                      : () {
                          setState(() => _timer = v);
                          widget.onSleepDurationChanged!(
                              v == null ? Duration.zero : Duration(minutes: v));
                        },
                ),
            ],
          ),
          if (widget.onToggleDanmaku != null)
            _section(
              '弹幕',
              [
                for (final on in const [true, false])
                  _TvChip(
                    label: on ? '开启' : '关闭',
                    selected: _danmaku == on,
                    onTap: () {
                      if (_danmaku == on) return;
                      setState(() => _danmaku = on);
                      widget.onToggleDanmaku!();
                    },
                  ),
              ],
            ),
          const SizedBox(height: 8),
          _TvTile(
            icon: CupertinoIcons.arrow_down_to_line,
            title: widget.isOfflinePlayback ? '已下载到本地' : '下载到本地',
            onTap: widget.canDownload
                ? () => widget.onSelected(PlayerMenuAction.download)
                : null,
          ),
          const SizedBox(height: 28),
          const Text(
            '按返回键关闭',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  List<Widget> _qualityChips() {
    if (_loadingQualities) {
      return const [_TvChip(label: '加载中…', selected: false)];
    }
    if (_qualityFailed) {
      return [
        _TvChip(label: '加载失败，重试', selected: false, onTap: _loadQualities)
      ];
    }
    if (_qualities.isEmpty) {
      return [
        _TvChip(
          label: widget.isOfflinePlayback ? '本地画质' : '暂无可选',
          selected: false,
        ),
      ];
    }
    return [
      for (final q in _qualities)
        _TvChip(
          label: q.toUpperCase(),
          selected: q == _quality,
          onTap: widget.onQualityChanged == null
              ? null
              : () {
                  setState(() => _quality = q);
                  widget.onQualityChanged!(q);
                },
        ),
    ];
  }

  Widget _section(String title, List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          // 每行固定 3 个等宽格子：选项多时整齐换行，不会有单个落到下一行的“孤儿”
          LayoutBuilder(builder: (context, constraints) {
            const gap = 10.0;
            final cell = (constraints.maxWidth - gap * 2) / 3;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final chip in chips) SizedBox(width: cell, child: chip),
              ],
            );
          }),
        ],
      ),
    );
  }
}

/// 可聚焦的基础件：OK/回车触发，聚焦时回调 builder 重绘。
class _Focusable extends StatefulWidget {
  const _Focusable({
    required this.builder,
    this.onTap,
    this.autofocus = false,
  });

  final Widget Function(bool focused) builder;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  State<_Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<_Focusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: widget.onTap != null,
      autofocus: widget.autofocus,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap?.call();
          return null;
        }),
      },
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) {
          Scrollable.ensureVisible(context,
              alignment: 0.5, duration: const Duration(milliseconds: 150));
        }
      },
      mouseCursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _focused ? 1.06 : 1,
          duration: const Duration(milliseconds: 120),
          child: widget.builder(_focused),
        ),
      ),
    );
  }
}

class _TvChip extends StatelessWidget {
  const _TvChip({
    required this.label,
    required this.selected,
    this.onTap,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return _Focusable(
      onTap: onTap,
      autofocus: autofocus,
      builder: (focused) {
        final Color bg = focused
            ? Colors.white
            : selected
                ? _brand
                : Colors.white.withAlpha(22);
        final Color fg = focused
            ? (selected ? _brand : Colors.black)
            : selected
                ? Colors.white
                : onTap == null
                    ? Colors.white38
                    : Colors.white70;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
          ),
          // widthFactor: 1 → 按文字宽度收缩，几个选项排成一行
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 15,
                fontWeight:
                    selected || focused ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TvTile extends StatelessWidget {
  const _TvTile({
    required this.icon,
    required this.title,
    this.onTap,
    this.autofocus = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return _Focusable(
      onTap: onTap,
      autofocus: autofocus,
      builder: (focused) {
        final fg = focused
            ? Colors.black
            : onTap == null
                ? Colors.white38
                : Colors.white;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withAlpha(16),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, color: fg, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: fg,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: fg.withAlpha(150), size: 22),
            ],
          ),
        );
      },
    );
  }
}
