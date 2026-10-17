import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'detail_episode_strip.dart';

/// 手机详情页底栏，播放卡片在前，缓存作为右侧辅助操作。
class DetailActionBar extends StatelessWidget {
  const DetailActionBar({
    super.key,
    required this.onPlay,
    this.onDownload,
    this.addingDownloads = false,
  });

  final VoidCallback onPlay;
  final VoidCallback? onDownload;
  final bool addingDownloads;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.white,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _PlayAction(onPressed: onPlay)),
                  if (onDownload != null) ...[
                    const SizedBox(width: 10),
                    _DownloadAction(
                      onPressed: addingDownloads ? null : onDownload,
                      addingDownloads: addingDownloads,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}

class _DownloadAction extends StatelessWidget {
  const _DownloadAction({
    required this.onPressed,
    required this.addingDownloads,
  });

  final VoidCallback? onPressed;
  final bool addingDownloads;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 64,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFFF6F7F9),
            foregroundColor: const Color(0xFF515866),
            disabledForegroundColor: const Color(0xFF969CA6),
            minimumSize: const Size(64, 64),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            side: const BorderSide(color: Color(0xFFECEEF2)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 22,
                width: 22,
                child: addingDownloads
                    ? const Center(child: CupertinoActivityIndicator(radius: 9))
                    : const Icon(CupertinoIcons.arrow_down_to_line, size: 22),
              ),
              const SizedBox(height: 5),
              Text(
                addingDownloads ? '添加中' : '缓存',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      );
}

class _PlayAction extends StatelessWidget {
  const _PlayAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: detailAccent,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(64),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: SizedBox.square(
                dimension: 34,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: Icon(CupertinoIcons.play_fill,
                        size: 15, color: detailAccent),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '立即播放',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '从第1集开始',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .8),
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
