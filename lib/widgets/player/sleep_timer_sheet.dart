import 'package:flutter/material.dart';

/// null 表示返回不修改；Duration.zero 表示取消已有定时。
Future<Duration?> showSleepTimerSheet({
  required BuildContext context,
  required Duration remaining,
  required bool isActive,
}) {
  final media = MediaQuery.of(context);
  final landscape = media.size.width > media.size.height;
  Widget panel(BuildContext context) => _SleepTimerPanel(
        minutesLeft: (remaining.inSeconds / 60).ceil(),
        isActive: isActive,
        landscape: landscape,
      );
  if (landscape) {
    return showDialog<Duration>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: panel(context),
        ),
      ),
    );
  }
  return showModalBottomSheet<Duration>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    isScrollControlled: true,
    useSafeArea: true,
    builder: panel,
  );
}

class _SleepTimerPanel extends StatelessWidget {
  const _SleepTimerPanel({
    required this.minutesLeft,
    required this.isActive,
    required this.landscape,
  });

  final int minutesLeft;
  final bool isActive;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final bottom = landscape ? 0.0 : MediaQuery.of(context).viewPadding.bottom;
    return Material(
      color: Colors.white.withValues(alpha: 0.96),
      shape: RoundedRectangleBorder(
        borderRadius: landscape
            ? BorderRadius.circular(24)
            : const BorderRadius.vertical(top: Radius.circular(24)),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, landscape ? 20 : 10, 20, bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!landscape) ...[
            Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 18),
          ],
          Row(children: [
            Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                    color: const Color(0xFFD95C6E).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.bedtime_outlined,
                    color: Color(0xFFD95C6E))),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text('定时关闭',
                      style: TextStyle(
                          color: Color(0xFF1A1A1A),
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(isActive ? '约 $minutesLeft 分钟后停止播放' : '到时停止播放，并允许屏幕休眠',
                      style: const TextStyle(
                          color: Color(0xFF757575), fontSize: 12, height: 1.4)),
                ])),
            IconButton(
                tooltip: '关闭定时设置',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded,
                    color: Color(0xFF424242), size: 20)),
          ]),
          const SizedBox(height: 22),
          const Align(
              alignment: Alignment.centerLeft,
              child: Text('选择时长',
                  style: TextStyle(color: Color(0xFF757575), fontSize: 12))),
          const SizedBox(height: 10),
          LayoutBuilder(builder: (context, constraints) {
            final width = (constraints.maxWidth - 16) / 3;
            return Wrap(spacing: 8, runSpacing: 8, children: [
              for (final minutes in [15, 30, 60, 90, 120])
                _TimerOption(
                    width: width,
                    label: '$minutes 分钟',
                    duration: Duration(minutes: minutes)),
              _TimerOption(
                  width: width,
                  label: isActive ? '取消定时' : '暂不设置',
                  duration: isActive ? Duration.zero : null,
                  secondary: true),
            ]);
          }),
        ]),
      ),
    );
  }
}

class _TimerOption extends StatelessWidget {
  const _TimerOption(
      {required this.width,
      required this.label,
      required this.duration,
      this.secondary = false});
  final double width;
  final String label;
  final Duration? duration;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: secondary ? const Color(0xFFF3F4F6) : const Color(0xFFF3F4F6),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
                color: secondary
                    ? Colors.black.withValues(alpha: 0.06)
                    : const Color(0xFFD95C6E).withValues(alpha: 0.28))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.pop(context, duration),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 17),
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: secondary
                        ? const Color(0xFF4B5563)
                        : const Color(0xFFB34B5B),
                    fontSize: 13,
                    height: 1.3,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}
