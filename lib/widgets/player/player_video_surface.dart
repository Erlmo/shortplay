import 'package:flutter/material.dart';

/// 仅横屏全屏完整等比显示；竖屏按铺满布局显示。
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
    final contain = isLandscapeFullScreen;
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
