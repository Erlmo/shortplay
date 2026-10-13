import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/device_profile.dart';

/// 电视 / 桌面横屏时，底部弹层改用右侧全高侧边面板：底部弹层在横屏上
/// 只露出一两行，遥控器也够不着下面的内容。
bool useSidePanel(BuildContext context) {
  final size = MediaQuery.of(context).size;
  return DeviceProfile.usesFocusUi && size.width > size.height;
}

/// 从右侧滑出的全高面板。返回键 / 点击遮罩关闭。
Future<T?> showSidePanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double widthFraction = 0.42,
  double minWidth = 400,
  Color color = Colors.white,
  Color? barrierColor,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: barrierColor ?? Colors.black.withAlpha(120),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, __) {
      final size = MediaQuery.of(context).size;
      final width =
          math.min(size.width, math.max(minWidth, size.width * widthFraction));
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: width,
          height: size.height,
          child: Material(
            color: color,
            elevation: color.a < 1 ? 0 : 12,
            child: SafeArea(left: false, child: builder(context)),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      ),
      child: child,
    ),
  );
}
