import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';

/// 顶部滚动公告栏：拉取 /notice 列表，多条时纵向轮播切换。
/// 加载失败或为空时整体隐藏（占位高度 0），不打扰布局。
class NoticeBar extends StatefulWidget {
  const NoticeBar({super.key, required this.apiClient});

  final ApiClient apiClient;

  @override
  State<NoticeBar> createState() => _NoticeBarState();
}

class _NoticeBarState extends State<NoticeBar> {
  List<String> _notices = const [];
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadNotices();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadNotices() async {
    try {
      final notices = await widget.apiClient.fetchNotice();
      if (!mounted || notices.isEmpty) return;
      setState(() => _notices = notices);
      if (notices.length > 1) _startRolling();
    } catch (_) {
      // 公告非核心功能，失败静默隐藏。
    }
  }

  void _startRolling() {
    _timer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted) return;
      setState(() => _index = (_index + 1) % _notices.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_notices.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 34,
      // 水平 8 对齐首页网格卡片的左右边缘（网格 SliverPadding 水平 8）。
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6F0),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.campaign_rounded,
            size: 18,
            color: Color(0xFFFF7D27),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              // 本版本 AnimatedSwitcher 无 alignment 参数；自定义 layoutBuilder
              // 把默认的居中堆叠改为左对齐，否则公告文字会居中。
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              transitionBuilder: (child, anim) {
                // 上滑切换：新公告从下方推入。
                final offset = Tween<Offset>(
                  begin: const Offset(0, 0.6),
                  end: Offset.zero,
                ).animate(anim);
                return ClipRect(
                  child: SlideTransition(
                    position: offset,
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                );
              },
              child: Text(
                _notices[_index],
                key: ValueKey(_index),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFB35418),
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
