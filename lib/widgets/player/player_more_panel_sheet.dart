part of 'player_more_menu.dart';

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
          Text(label, style: const TextStyle(color: _pnMuted, fontSize: 13)),
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
