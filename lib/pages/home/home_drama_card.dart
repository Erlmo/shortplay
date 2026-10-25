import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/drama.dart';
import '../../services/api_client.dart';
import '../../services/device_profile.dart';
import '../../services/download_service.dart';
import '../../widgets/tv_tap.dart';
import '../drama_detail_page.dart';

/// 首页双列海报卡片（小红书风格）。
class HomeDramaCard extends StatelessWidget {
  const HomeDramaCard({
    super.key,
    required this.drama,
    required this.apiClient,
    this.downloadService,
  });

  final Drama drama;
  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  Widget build(BuildContext context) {
    return TvTap(
      borderRadius: DeviceProfile.isTv ? 14 : 12,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DramaDetailPage(
              drama: drama,
              apiClient: apiClient,
              downloadService: downloadService,
            ),
          ),
        );
      },
      child: Container(
        padding: DeviceProfile.isTv ? const EdgeInsets.all(8) : EdgeInsets.zero,
        decoration: DeviceProfile.isTv
            ? BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE8EBF0)),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[200],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: drama.cover,
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) =>
                          Container(color: Colors.grey[200]),
                    ),
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          (drama.playCnt ?? 0) > 10000
                              ? '${((drama.playCnt ?? 0) / 10000).toInt()}万'
                              : '${drama.playCnt ?? 0}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    // 左上角徽标
                    if (drama.tagInfo != null && drama.tagInfo!.text.isNotEmpty)
                      _buildTopBadge(
                        drama.tagInfo!.text,
                        _parseColor(
                          drama.tagInfo!.bgColor.isNotEmpty
                              ? drama.tagInfo!.bgColor.first
                              : '',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              drama.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1D1D1F),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              drama.subTitle ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
            ),
          ],
        ),
      ),
    );
  }

  Color _parseColor(String colorStr) {
    if (colorStr.isEmpty) return const Color(0xFFFF2442);
    try {
      final hex = colorStr.replaceAll('#', '');
      if (hex.length == 6) {
        return Color(int.parse('0xFF$hex'));
      } else if (hex.length == 8) {
        return Color(int.parse('0x$hex'));
      }
    } catch (_) {}
    return const Color(0xFFFF2442);
  }

  Widget _buildTopBadge(String text, Color color) {
    return Positioned(
      top: 8,
      left: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.9), // 稍微透明一点更有质感
          borderRadius: const BorderRadius.all(
            Radius.circular(4),
          ), // 小红书风格倾向于圆角矩形
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
