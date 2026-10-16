import 'package:flutter/material.dart';

import '../models/drama_season.dart';
import '../services/device_profile.dart';
import 'tv_tap.dart';

/// 选集区内的横向季标签，切季后保留当前详情页和遥控器焦点。
class RelatedSeasons extends StatefulWidget {
  const RelatedSeasons(
      {super.key,
      required this.seasons,
      required this.currentId,
      required this.onSelect});

  final List<DramaSeason> seasons;
  final int currentId;
  final ValueChanged<DramaSeason> onSelect;

  @override
  State<RelatedSeasons> createState() => _RelatedSeasonsState();
}

class _RelatedSeasonsState extends State<RelatedSeasons> {
  final _scrollController = ScrollController();
  double get _tabWidth => DeviceProfile.isTv ? 92 : 64;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  @override
  void didUpdateWidget(RelatedSeasons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentId != widget.currentId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
    }
  }

  void _revealCurrent() {
    if (!mounted || !_scrollController.hasClients) return;
    final index = widget.seasons.indexWhere((s) => s.id == widget.currentId);
    if (index < 0) return;
    final position = _scrollController.position;
    _scrollController.animateTo(
        (index * (_tabWidth + 8) -
                position.viewportDimension / 2 +
                _tabWidth / 2)
            .clamp(0.0, position.maxScrollExtent),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFF0F1F5)))),
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: widget.seasons.map((season) {
            final current = season.id == widget.currentId;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Semantics(
                button: true,
                selected: current,
                label:
                    '${season.title}，第${season.order}季${current ? '，当前季' : ''}',
                child: TvTap(
                  key: ValueKey('related-season-${season.id}'),
                  borderRadius: 9,
                  focusScale: 1,
                  onTap: () => widget.onSelect(season),
                  child: SizedBox(
                    width: _tabWidth,
                    height: 44,
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                              child: Center(
                                  child: AnimatedDefaultTextStyle(
                                      duration:
                                          const Duration(milliseconds: 160),
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: current
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: current
                                              ? const Color(0xFFFF3455)
                                              : const Color(0xFF969CAB)),
                                      child: Text('第${season.order}季')))),
                          AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              width: current ? 24 : 0,
                              height: 3,
                              decoration: BoxDecoration(
                                  color: const Color(0xFFFF3455),
                                  borderRadius: BorderRadius.circular(3))),
                        ]),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
