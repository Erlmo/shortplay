import 'package:flutter/material.dart';

/// 横向视频及横屏全屏均完整等比显示；竖屏页面的竖向视频铺满显示。
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

  @override
  Widget build(BuildContext context) {
    final hasSize = videoWidth > 0 && videoHeight > 0;
    final width = hasSize ? videoWidth.toDouble() : 9.0;
    final height = hasSize ? videoHeight.toDouble() : 16.0;
    // 竖屏页面遇到横向视频时，也要保留横向画幅，配合控制层的“全屏显示”按钮。
    // 只有竖屏视频在普通竖屏页面才铺满裁剪；进入横屏全屏后始终完整等比显示。
    final contain = isLandscapeFullScreen || width > height;
    return ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(
        child: FittedBox(
          fit: contain ? BoxFit.contain : BoxFit.cover,
          alignment: contain ? Alignment.center : const Alignment(0, 0.45),
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: width,
            height: height,
            child: Texture(textureId: textureId),
          ),
        ),
      ),
    );
  }
}
