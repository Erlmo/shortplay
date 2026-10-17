import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 按用户要求启用红果 j65.u 的裁切优化分支（模式7）：
/// 竖屏普通片源先铺满，整轴裁掉比例超过15%则完整显示；横向片源按宽。
/// 手机底栏单独保留固定高度，留白属于画面区域，不扩展控件栏。
/// 横屏默认完整显示，可由用户切换为等比例铺满。
class PlayerVideoSurface extends StatelessWidget {
  const PlayerVideoSurface({
    super.key,
    required this.textureId,
    required this.videoWidth,
    required this.videoHeight,
    required this.isLandscapeFullScreen,
    this.fillScreen = false,
  });

  final int textureId;
  final int videoWidth;
  final int videoHeight;
  final bool isLandscapeFullScreen;
  final bool fillScreen;

  /// 片源宽/高达到此值视为横版片源（红果 landscape_ratio 默认 1.666）。
  static const double landscapeRatio = 1.666;

  /// 屏幕宽/高超过此值视为宽屏设备（红果 wide_screen_boundary 默认 0.8）。
  static const double wideScreenBoundary = 0.8;

  /// 用户要求底栏比原56dp增加8dp；这是本项目布局适配，并非红果默认值。
  /// iOS 隐藏 Home 指示条后仍可能保留安全区，不能再叠加到栏高。
  static const double phoneBottomBarHeight = 64;

  static const double cropThreshold = 0.15;

  /// 画面区域底部两个角的圆角半径。圆角外露出的是控件栏的底色，
  /// 看起来像控件栏向上托住画面，两者衔接成一体（红果做法）。
  static const double phoneBarCornerRadius = 20;

  /// 底部控件栏底色（圆角外露出的颜色要和它一致）
  static const Color phoneBarColor = Color(0xFF161616);

  /// 画面区域高度：控件栏以上。
  static double phoneVideoAreaHeight(Size box) =>
      box.height - phoneBottomBarHeight;

  /// 是否使用竖屏手机布局（底部固定控件栏 + 画面贴顶）。
  static bool usesPhoneLayout(Size size, bool isLandscapeFullScreen) =>
      !isLandscapeFullScreen && size.width / size.height <= wideScreenBoundary;

  static Rect _scaledRect(
      Size area, double width, double height, double scale) {
    final w = width * scale;
    final h = height * scale;
    return Rect.fromLTWH((area.width - w) / 2, (area.height - h) / 2, w, h);
  }

  /// 裁切比例以放大后的画面为分母，左右/上下两侧合计，而非每侧15%。
  static Rect phoneVideoRect(Size box, double width, double height) {
    final area = Size(box.width, math.max(0, phoneVideoAreaHeight(box)));
    final coverScale = math.max(area.width / width, area.height / height);
    final cover = _scaledRect(area, width, height, coverScale);
    if (width / height >= landscapeRatio) {
      return _scaledRect(area, width, height, area.width / width);
    }
    final cutX = (cover.width - area.width) / cover.width;
    final cutY = (cover.height - area.height) / cover.height;
    if (cutX > cropThreshold || cutY > cropThreshold) {
      final fitScale = math.min(area.width / width, area.height / height);
      return _scaledRect(area, width, height, fitScale);
    }
    return cover;
  }

  @override
  Widget build(BuildContext context) {
    // 尺寸还没上报时先不画：按默认比例画会把横屏片源拉伸。原生侧在首帧
    // 之前/同时就会上报尺寸，所以这里最多黑一瞬间。
    if (videoWidth <= 0 || videoHeight <= 0) {
      return const ColoredBox(color: Colors.black);
    }
    final width = videoWidth.toDouble();
    final height = videoHeight.toDouble();
    final texture = Texture(textureId: textureId);

    return LayoutBuilder(builder: (context, constraints) {
      final box = Size(constraints.maxWidth, constraints.maxHeight);
      final phone = box.width.isFinite &&
          box.height.isFinite &&
          usesPhoneLayout(box, isLandscapeFullScreen);

      if (!phone) {
        return ColoredBox(
          color: Colors.black,
          child: SizedBox.expand(
            child: FittedBox(
              fit: fillScreen && box.width > box.height
                  ? BoxFit.cover
                  : BoxFit.contain,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(width: width, height: height, child: texture),
            ),
          ),
        );
      }

      final r = phoneVideoRect(box, width, height);
      final areaH = phoneVideoAreaHeight(box);
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            // 圆角外露出的底色：从圆角高度处起铺控件栏颜色
            Positioned(
              left: 0,
              right: 0,
              top: areaH - phoneBarCornerRadius,
              bottom: 0,
              child: const ColoredBox(color: phoneBarColor),
            ),
            // 只在控件栏以上区域内显示，裁掉溢出部分；底部两角圆角
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              height: areaH,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(phoneBarCornerRadius),
                ),
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [Positioned.fromRect(rect: r, child: texture)],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
