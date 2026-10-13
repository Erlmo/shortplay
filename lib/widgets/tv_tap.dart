import 'package:flutter/material.dart';

import '../services/device_profile.dart';

/// 可替代只用 onTap 的 [GestureDetector]（或 `ink: true` 时替代 [InkWell]）。
///
/// 手机上就是原来的 GestureDetector，行为不变；电视/桌面上额外变成可聚焦：
/// 方向键可以选中，确认键（OK/Enter/空格）触发 [onTap]，选中时显示主题色
/// 描边并轻微放大，隔着沙发也看得清。
class TvTap extends StatefulWidget {
  const TvTap({
    super.key,
    required this.onTap,
    required this.child,
    this.behavior,
    this.borderRadius = 12,
    this.autofocus = false,
    this.focusScale = 1.04,
    this.ink = false,
    this.ringColor,
  });

  final VoidCallback? onTap;
  final Widget child;
  final HitTestBehavior? behavior;
  final double borderRadius;
  final bool autofocus;
  final double focusScale;

  /// true：用 InkWell 保留点击水波纹（替换原来的 InkWell 时用）。
  final bool ink;

  /// 焦点描边颜色，默认主题主色；深色背景上可传白色。
  final Color? ringColor;

  @override
  State<TvTap> createState() => _TvTapState();
}

class _TvTapState extends State<TvTap> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final focusUi = DeviceProfile.usesFocusUi;
    final Widget tap = widget.ink
        ? InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(widget.borderRadius),
            // 焦点由外层 FocusableActionDetector 管，避免一个卡片两个焦点节点
            canRequestFocus: !focusUi,
            child: widget.child,
          )
        : GestureDetector(
            behavior: widget.behavior,
            onTap: widget.onTap,
            child: widget.child,
          );
    if (!focusUi) return tap;

    final color = widget.ringColor ?? Theme.of(context).colorScheme.primary;
    return FocusableActionDetector(
      enabled: widget.onTap != null,
      autofocus: widget.autofocus,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (v) {
        if (v != _focused) setState(() => _focused = v);
        if (v) {
          // 让被选中的卡片滚动到可见区域
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 150),
          );
        }
      },
      child: AnimatedScale(
        scale: _focused ? widget.focusScale : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          foregroundDecoration: _focused
              ? BoxDecoration(
                  border: Border.all(color: color, width: 3),
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                )
              : null,
          child: tap,
        ),
      ),
    );
  }
}
