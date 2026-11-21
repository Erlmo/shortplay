import 'package:flutter/material.dart';

/// 播放页上层的提示类组件：遥控器按键提示、错误页、下一集加载圈、
/// “下一集加载中”胶囊、底边手势保护区，以及阻止向前翻页的滚动物理。

/// 电视端首次进入播放页时的按键说明。
class PlayerKeyHint extends StatelessWidget {
  const PlayerKeyHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 96,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(170),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Text(
              '↑↓ 切集   ←→ 快退/快进   OK 暂停   长按 OK / 菜单键 选集·倍速·清晰度',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}

/// 整页加载失败：错误信息 + 返回按钮。
class PlayerErrorView extends StatelessWidget {
  const PlayerErrorView({super.key, required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message ?? '未知错误',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}

/// 底部的小号加载圈（下一集准备中）。
class PlayerNextLoading extends StatelessWidget {
  const PlayerNextLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      bottom: 80,
      left: 0,
      right: 0,
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            color: Colors.white54,
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }
}

/// 屏幕底边是系统“上滑回桌面 / 呼出导航栏”的手势区。从这里起手的上滑
/// 交给系统，不让播放页的 PageView 接住（否则回桌面时会误翻到下一集）。
/// 只吞竖向拖动，点击照常落到下面的选集栏。
class PlayerBottomEdgeGuard extends StatelessWidget {
  const PlayerBottomEdgeGuard({super.key});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final zone = [
          media.systemGestureInsets.bottom,
          media.viewPadding.bottom,
          32.0,
        ].reduce((a, b) => a > b ? a : b) +
        8;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: zone,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) {},
        onVerticalDragUpdate: (_) {},
        onVerticalDragEnd: (_) {},
      ),
    );
  }
}
