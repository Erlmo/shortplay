import 'package:flutter/material.dart';

import '../models/twixive.dart';

class TwixiveVideoCard extends StatelessWidget {
  const TwixiveVideoCard(
      {super.key,
      required this.video,
      required this.onTap,
      required this.onAuthorTap,
      this.rank});

  final TwixiveVideo video;
  final VoidCallback onTap;
  final VoidCallback onAuthorTap;
  final int? rank;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
            onTap: onTap,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: Stack(fit: StackFit.expand, children: [
                ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: _Cover(url: video.thumbnail)),
                Positioned(
                    left: 10,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: const BoxDecoration(
                          color: Colors.black38, shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 18),
                    )),
                if (rank != null)
                  Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                            color: rank! <= 3
                                ? const Color(0xFFFF2442)
                                : Colors.black54,
                            borderRadius: BorderRadius.circular(7)),
                        child: Text('$rank',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 12)),
                      )),
              ])),
              InkWell(
                  onTap:
                      video.author.identifier.isNotEmpty ? onAuthorTap : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
                    child: Row(children: [
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(
                                video.author.label.isEmpty
                                    ? '视频'
                                    : video.author.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF292D35))),
                            const SizedBox(height: 3),
                            Text(
                                video.author.username.isEmpty
                                    ? '查看视频'
                                    : '@${video.author.username}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 11, color: Color(0xFF9196A0))),
                          ])),
                      if (video.author.identifier.isNotEmpty)
                        const Icon(Icons.chevron_right_rounded,
                            size: 15, color: Color(0xFFB0B4BD)),
                    ]),
                  )),
            ])),
      );
}

class TwixiveUserCard extends StatelessWidget {
  const TwixiveUserCard({super.key, required this.user, this.onTap, this.rank});

  final TwixiveUser user;
  final VoidCallback? onTap;
  final int? rank;

  String get _followers => user.followersCount >= 10000
      ? '${(user.followersCount / 10000).toStringAsFixed(1)}万'
      : '${user.followersCount}';

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
            onTap: onTap,
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  if (rank != null) ...[
                    SizedBox(
                        width: 24,
                        child: Text('$rank',
                            style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                                color: rank! <= 3
                                    ? const Color(0xFFFF2442)
                                    : const Color(0xFF9A9EAA)))),
                    const SizedBox(width: 10),
                  ],
                  ClipOval(
                      child: SizedBox(
                          width: 48,
                          height: 48,
                          child: _Cover(
                              url: user.avatar,
                              icon: Icons.person_outline_rounded))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(user.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('@${user.username} · $_followers 位关注者',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF858B96))),
                      ])),
                  if (onTap != null)
                    const Icon(Icons.chevron_right_rounded,
                        color: Color(0xFFA0A5AF), size: 22),
                ]))),
      );
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url, this.icon = Icons.movie_outlined});
  final String url;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
        color: const Color(0xFFECEEF2),
        child: Center(
            child: Icon(icon, color: const Color(0xFFB0B5C0), size: 30)));
    if (url.isEmpty) return placeholder;
    return Image.network(url,
        fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder);
  }
}
