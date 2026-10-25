import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/drama.dart';
import '../../services/api_client.dart';
import '../../services/device_profile.dart';
import '../../services/download_service.dart';
import '../../widgets/tv_tap.dart';
import '../drama_detail_page.dart';

// 排行榜列表项组件
class RankListItem extends StatelessWidget {
  const RankListItem({
    super.key,
    required this.drama,
    required this.apiClient,
    this.downloadService,
    this.rank,
  });

  final Drama drama;
  final ApiClient apiClient;
  final DownloadService? downloadService;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    return TvTap(
      ink: true,
      borderRadius: 0,
      focusScale: 1.0,
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
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: DeviceProfile.isTv ? BorderRadius.circular(12) : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面图 + 排名
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 85,
                height: 113,
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
                      top: 0,
                      left: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _getRankColor(rank!),
                          borderRadius: const BorderRadius.only(
                            bottomRight: Radius.circular(6),
                          ),
                        ),
                        child: Text(
                          '$rank',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 右侧信息
            Expanded(
              child: SizedBox(
                height: 113,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // 第一行：标题 + 推荐
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            drama.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1D1D1F),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.whatshot,
                              size: 12,
                              color: Color(0xFFFF7D27),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${drama.score}分推荐',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFFF7D27),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // 第二行：副标题 (分类·集数·作者)
                    Text(
                      drama.subTitle ?? '都市 · 80集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF86868B),
                      ),
                    ),

                    // 第三行：描述/简介
                    Text(
                      (drama.intro.isNotEmpty ? drama.intro : '暂无简介'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF86868B),
                        height: 1.3,
                      ),
                    ),

                    // 第四行：统计标签
                    Row(
                      children: [
                        if (drama.recText != null)
                          _buildStatTag(drama.recText!),
                        if (drama.recText != null) const SizedBox(width: 6),
                        if (drama.secondaryInfoList != null &&
                            drama.secondaryInfoList!.isNotEmpty &&
                            drama.secondaryInfoList!.length > 1)
                          _buildStatTag(drama.secondaryInfoList![1].content)
                        else if (drama.secondaryInfoList != null &&
                            drama.secondaryInfoList!.isNotEmpty)
                          _buildStatTag(drama.secondaryInfoList![0].content),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getRankColor(int rank) {
    switch (rank) {
      case 1:
        return const Color(0xFFFF7D27); // Orange
      case 2:
        return const Color(0xFF2DC3A6); // Teal
      case 3:
        return const Color(0xFF5E85F7); // Blue
      default:
        return const Color(0x99000000); // Overlay Black
    }
  }

  Widget _buildStatTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0), // Light Orange
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFE65100), // Dark Orange
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
