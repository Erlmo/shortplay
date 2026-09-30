import 'dart:math' as math;

import 'package:flutter/material.dart';

enum AppNoticeKind { success, info, error }

/// 统一操作反馈，连续操作时仅保留最新提示，避免消息排队遮挡界面。
void showAppNotice(
  BuildContext context, {
  required String message,
  String? detail,
  AppNoticeKind kind = AppNoticeKind.info,
  IconData? icon,
  bool abovePlayerControls = false,
}) {
  final media = MediaQuery.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final horizontal = math.max(16.0, (media.size.width - 440) / 2);
  final bottom = abovePlayerControls ? 82.0 : 16.0;
  messenger.clearSnackBars();
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    margin: EdgeInsets.fromLTRB(horizontal, 0, horizontal, bottom),
    duration: Duration(seconds: kind == AppNoticeKind.error ? 5 : 3),
    dismissDirection: DismissDirection.horizontal,
    content: AppNoticeCard(
      message: message,
      detail: detail,
      kind: kind,
      icon: icon,
      onDismiss: messenger.hideCurrentSnackBar,
    ),
  ));
}

class AppNoticeCard extends StatelessWidget {
  const AppNoticeCard({
    super.key,
    required this.message,
    this.detail,
    this.kind = AppNoticeKind.info,
    this.icon,
    required this.onDismiss,
  });

  final String message;
  final String? detail;
  final AppNoticeKind kind;
  final IconData? icon;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final (color, defaultIcon) = switch (kind) {
      AppNoticeKind.success => (const Color(0xFF4ADE80), Icons.check_rounded),
      AppNoticeKind.info => (
          const Color(0xFFFF7588),
          Icons.info_outline_rounded
        ),
      AppNoticeKind.error => (
          const Color(0xFFFF657B),
          Icons.error_outline_rounded
        ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 20,
              offset: const Offset(0, 6))
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11)),
            child: Icon(icon ?? defaultIcon, color: color, size: 20),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.45,
                        fontWeight: FontWeight.w600)),
                if (detail != null) ...[
                  const SizedBox(height: 3),
                  Text(detail!,
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.45,
                          color: Colors.white.withValues(alpha: 0.55))),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭提示',
            onPressed: onDismiss,
            style: IconButton.styleFrom(minimumSize: const Size(36, 40)),
            icon: Icon(Icons.close_rounded,
                size: 16, color: Colors.white.withValues(alpha: 0.45)),
          ),
        ]),
      ),
    );
  }
}
