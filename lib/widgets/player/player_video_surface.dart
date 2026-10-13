import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 视频画面的缩放规则（与红果短剧播放器一致，见 j65/h.java onLayout）：
/// - 竖屏手机：底部留出固定高度的控件栏（[phoneBottomBarHeight]），画面区域
///   是“屏幕顶端（透明状态栏压在画面上）到控件栏上沿”；
///   * 竖版片源：在画面区域里**铺满裁切**（ASPECT_FILL），不设裁切上限，
///     画面下沿永远贴着控件栏，两者无缝衔接；
///   * 横版片源（宽/高 ≥ [landscapeRatio]）：完整显示（按宽撑满）。
/// - 横屏全屏、手机横过来、宽屏设备（屏幕宽/高 > [wideScreenBoundary]，
///   如平板 / 折叠屏 / 电视 / 桌面宽窗口）：完整显示。
class PlayerVideoSurface extends StatelessWidget {
  const PlayerVideoSurface({
    super.key,
    required this.textureId,
    required this.videoWidth,
    required this.videoHeight,
    required this.isLandscapeFullScreen,
  });

  final int textureId;
  final int videoWidth;
  final int videoHeight;
  final bool isLandscapeFullScreen;

  /// 片源宽/高达到此值视为横版片源（红果 landscape_ratio 默认 1.666）。
  static const double landscapeRatio = 1.666;

  /// 屏幕宽/高超过此值视为宽屏设备（红果 wide_screen_boundary 默认 0.8）。
  static const double wideScreenBoundary = 0.8;

  /// 竖屏手机底部固定控件栏高度（红果默认 56dp）+ 系统手势条 / Home 指示条。
  static double phoneBottomBarHeight(MediaQueryData media) =>
      56 + media.viewPadding.bottom;

  /// 画面区域底部两个角的圆角半径。圆角外露出的是控件栏的底色，
  /// 看起来像控件栏向上托住画面，两者衔接成一体（红果做法）。
  static const double phoneBarCornerRadius = 20;

  /// 底部控件栏底色（圆角外露出的颜色要和它一致）
  static const Color phoneBarColor = Color(0xFF161616);

  /// 画面区域高度：控件栏以上。
  static double phoneVideoAreaHeight(Size box, MediaQueryData media) =>
      box.height - phoneBottomBarHeight(media);

  /// 是否使用竖屏手机布局（底部固定控件栏 + 画面贴顶）。
  static bool usesPhoneLayout(Size size, bool isLandscapeFullScreen) =>
      !isLandscapeFullScreen && size.width / size.height <= wideScreenBoundary;

  /// 竖屏手机 + 竖版片源：画面在整块屏幕坐标里的位置（铺满控件栏以上区域）。
  static Rect phoneFillRect(
      Size box, MediaQueryData media, double width, double height) {
    final areaH = phoneVideoAreaHeight(box, media);
    final scale = math.max(box.width / width, areaH / height);
    final drawW = width * scale;
    final drawH = height * scale;
    return Rect.fromLTWH(
        (box.width - drawW) / 2, (areaH - drawH) / 2, drawW, drawH);
  }

  /// 该片源在竖屏手机上是否铺满裁切（否则完整显示）。
  static bool fillsOnPhone(int videoWidth, int videoHeight) =>
      videoWidth > 0 &&
      videoHeight > 0 &&
      videoWidth / videoHeight < landscapeRatio;

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
      final fill = box.width.isFinite &&
          box.height.isFinite &&
          usesPhoneLayout(box, isLandscapeFullScreen) &&
          width / height < landscapeRatio;

      if (!fill) {
        return ColoredBox(
          color: Colors.black,
          child: SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.contain,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(width: width, height: height, child: texture),
            ),
          ),
        );
      }

      final r = phoneFillRect(box, MediaQuery.of(context), width, height);
      final areaH = phoneVideoAreaHeight(box, MediaQuery.of(context));
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
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [Positioned.fromRect(rect: r, child: texture)],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
