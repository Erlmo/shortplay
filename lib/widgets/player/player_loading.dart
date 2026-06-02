import 'package:flutter/material.dart';

import '../../models/workflow_step.dart';

class PlayerWorkflowProgress extends StatelessWidget {
  const PlayerWorkflowProgress({
    super.key,
    required this.steps,
    required this.loadingStatusText,
  });

  final List<WorkflowStep> steps;
  final String loadingStatusText;

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.white),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    strokeWidth: 4,
                    color: Colors.black,
                    backgroundColor: Color(0x33000000),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'LOADING',
                  textAlign: TextAlign.center,
                  style: textTheme.titleMedium?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _statusText().toUpperCase(),
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(
                    color: Colors.black.withValues(alpha: 0.55),
                    fontWeight: FontWeight.w500,
                    fontFamily: 'monospace',
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _statusText() {
    for (final step in steps) {
      if (step.status == StepStatus.running) return step.label;
    }
    return loadingStatusText;
  }
}

class PlayerPlaceholder extends StatelessWidget {
  const PlayerPlaceholder({
    super.key,
    required this.loading,
    required this.steps,
    required this.loadingStatusText,
    required this.errorMessage,
    required this.onRetry,
  });

  final bool loading;
  final List<WorkflowStep> steps;
  final String loadingStatusText;
  final String? errorMessage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      if (steps.isNotEmpty) {
        return PlayerWorkflowProgress(
          steps: steps,
          loadingStatusText: loadingStatusText,
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final error = errorMessage;
    if (error == null) return const SizedBox.shrink();

    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Colors.white54,
            size: 48,
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              error,
              style: textTheme.bodyLarge?.copyWith(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white30),
            ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class SwipeBlockedHint extends StatelessWidget {
  const SwipeBlockedHint({
    super.key,
    required this.visible,
  });

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(context).padding.bottom + 132,
      child: IgnorePointer(
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 0.45),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.86),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '下一集加载中',
                        style: textTheme.labelMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.keyboard_arrow_up_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                    ],
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

/// 点击选集跳转时的全屏 LOADING 覆盖层。盖住整个跳集过程，
/// 等目标集首帧渲染好后由调用方撤除，避免露出旧集画面或黑屏。
class EpisodeJumpLoadingOverlay extends StatelessWidget {
  const EpisodeJumpLoadingOverlay({
    super.key,
    this.statusText = '正在切换剧集',
  });

  final String statusText;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 52,
                height: 52,
                child: CircularProgressIndicator(
                  strokeWidth: 3.5,
                  color: Colors.white,
                  backgroundColor: Color(0x33FFFFFF),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                statusText,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
