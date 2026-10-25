import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum AppNoticeKind { success, info, error }

/// 当前显示中的提示；新提示出现时立即替换旧的，避免排队遮挡界面。
_AppNoticeHostState? _currentNotice;

/// 统一操作反馈：屏幕中部的半透明胶囊 toast，自动消失，点一下也可关闭。
///
/// [abovePlayerControls] 为 true 时（播放页）放在画面中上方，避开屏幕正中的
/// 暂停图标和底部的进度条 / 选集栏；普通页面放在偏下的位置。
void showAppNotice(
  BuildContext context, {
  required String message,
  String? detail,
  AppNoticeKind kind = AppNoticeKind.info,
  IconData? icon,
  bool abovePlayerControls = false,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _currentNotice?.removeNow();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _AppNoticeHost(
      alignment: abovePlayerControls
          ? const Alignment(0, -0.32)
          : const Alignment(0, 0.62),
      duration:
          Duration(milliseconds: kind == AppNoticeKind.error ? 3500 : 2200),
      onRemoved: () {
        if (entry.mounted) entry.remove();
      },
      child: AppNoticeCard(
        message: message,
        detail: detail,
        kind: kind,
        icon: icon,
      ),
    ),
  );
  overlay.insert(entry);
}

class _AppNoticeHost extends StatefulWidget {
  const _AppNoticeHost({
    required this.alignment,
    required this.duration,
    required this.onRemoved,
    required this.child,
  });

  final Alignment alignment;
  final Duration duration;
  final VoidCallback onRemoved;
  final Widget child;

  @override
  State<_AppNoticeHost> createState() => _AppNoticeHostState();
}

class _AppNoticeHostState extends State<_AppNoticeHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 160),
  );
  Timer? _timer;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    _currentNotice = this;
    _anim.forward();
    _timer = Timer(widget.duration, _dismiss);
  }

  /// 淡出后移除。
  Future<void> _dismiss() async {
    _timer?.cancel();
    if (_removed || !mounted) return;
    await _anim.reverse();
    removeNow();
  }

  /// 立即移除（被新提示替换时）。
  void removeNow() {
    if (_removed) return;
    _removed = true;
    _timer?.cancel();
    if (identical(_currentNotice, this)) _currentNotice = null;
    widget.onRemoved();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _anim.dispose();
    if (identical(_currentNotice, this)) _currentNotice = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: _anim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // 提示挂在根 Overlay 上，没有 Material 祖先：补一层透明 Material 继承主题字体。
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Align(
          alignment: widget.alignment,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: 0.92, end: 1.0).animate(curved),
                child: GestureDetector(
                  onTap: _dismiss,
                  child: Semantics(
                    liveRegion: true,
                    button: true,
                    onTapHint: '关闭提示',
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 提示内容：深色毛玻璃胶囊，可选状态徽标 + 主文案 + 次要说明。
class AppNoticeCard extends StatelessWidget {
  const AppNoticeCard({
    super.key,
    required this.message,
    this.detail,
    this.kind = AppNoticeKind.info,
    this.icon,
  });

  final String message;
  final String? detail;
  final AppNoticeKind kind;
  final IconData? icon;

  /// 状态徽标：成功 = 绿底对勾，失败 = 红底感叹号；普通提示默认不显示，
  /// 调用方传了 [icon] 时用白色图标。
  Widget? _badge() {
    final (Color? bg, IconData? glyph) = switch (kind) {
      AppNoticeKind.success => (const Color(0xFF2FC86B), Icons.check_rounded),
      AppNoticeKind.error => (
          const Color(0xFFFF3B55),
          Icons.priority_high_rounded
        ),
      AppNoticeKind.info => (null, null),
    };
    if (icon != null && bg == null) {
      return Icon(icon, size: 18, color: Colors.white);
    }
    if (bg == null) return null;
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon ?? glyph, size: 14, color: Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) {
    final badge = _badge();
    final hasDetail = detail != null && detail!.isNotEmpty;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(hasDetail ? 16 : 999),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xCC1C1C1E),
              borderRadius: BorderRadius.circular(hasDetail ? 16 : 999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: hasDetail ? 16 : 18,
                  vertical: hasDetail ? 12 : 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: hasDetail
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  if (badge != null) ...[
                    Padding(
                      padding: EdgeInsets.only(top: hasDetail ? 1 : 0),
                      child: badge,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            height: 1.4,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        if (hasDetail) ...[
                          const SizedBox(height: 2),
                          Text(
                            detail!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 12,
                              height: 1.4,
                              fontWeight: FontWeight.w400,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
