import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/search_suggestion.dart';
import '../services/device_profile.dart';
import 'tv_tap.dart';

class SearchSuggestionTile extends StatefulWidget {
  const SearchSuggestionTile({
    super.key,
    required this.suggestion,
    required this.onSearch,
    this.onPlay,
    this.focusNode,
  });

  final SearchSuggestion suggestion;
  final VoidCallback onSearch;
  final VoidCallback? onPlay;
  final FocusNode? focusNode;

  @override
  State<SearchSuggestionTile> createState() => _SearchSuggestionTileState();
}

class _SearchSuggestionTileState extends State<SearchSuggestionTile> {
  final _rowFocus = FocusNode();
  final _playFocus = FocusNode();
  SearchSuggestion get suggestion => widget.suggestion;
  VoidCallback get onSearch => widget.onSearch;
  VoidCallback? get onPlay => widget.onPlay;
  FocusNode get _effectiveRowFocus => widget.focusNode ?? _rowFocus;

  @override
  void dispose() {
    _rowFocus.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!DeviceProfile.isTv ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_playFocus.hasPrimaryFocus && key == LogicalKeyboardKey.arrowLeft) {
      _effectiveRowFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (_effectiveRowFocus.hasPrimaryFocus &&
        suggestion.showPlayButton &&
        onPlay != null &&
        key == LogicalKeyboardKey.arrowRight) {
      _playFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (_playFocus.hasPrimaryFocus &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      _effectiveRowFocus.requestFocus();
      _effectiveRowFocus.focusInDirection(key == LogicalKeyboardKey.arrowUp
          ? TraversalDirection.up
          : TraversalDirection.down);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tv = DeviceProfile.isTv;
    final rich = suggestion.isRich && suggestion.cover.isNotEmpty;
    final showPlay = suggestion.showPlayButton && onPlay != null;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tv ? 3 : 12, vertical: 4),
      child: Focus(
          canRequestFocus: false,
          onKeyEvent: _onKey,
          child: Material(
            color: rich ? const Color(0xFFF7F8FA) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            // 富卡两侧操作保持同高，封面旁与播放按钮上下都能点击。
            child: IntrinsicHeight(
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Expanded(
                      child: TvTap(
                    focusNode: _effectiveRowFocus,
                    // Padding 和 Row 的透明空白也属于这条联想的搜索区域。
                    behavior: HitTestBehavior.opaque,
                    borderRadius: 14,
                    focusScale: 1,
                    onTap: onSearch,
                    child: Padding(
                      padding: EdgeInsets.all(rich ? 12 : 14),
                      child: Row(
                        children: [
                          if (rich)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                suggestion.cover,
                                width: tv ? 48 : 46,
                                height: tv ? 64 : 62,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const SizedBox(
                                  width: 46,
                                  height: 62,
                                  child: Icon(Icons.movie_outlined,
                                      color: Colors.grey),
                                ),
                              ),
                            )
                          else
                            const Icon(Icons.search_rounded,
                                size: 20, color: Color(0xFF969CAA)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text.rich(
                                  _highlightedName(context),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: tv ? 17 : 15,
                                    height: 1.4,
                                    color: const Color(0xFF252A36),
                                    fontWeight: rich
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                                if (rich) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    suggestion.drama?.subTitle?.isNotEmpty ==
                                            true
                                        ? suggestion.drama!.subTitle!
                                        : '短剧',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 12, color: Color(0xFF8C93A1)),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 22,
                            color: const Color(0xFFB2B7C1),
                          ),
                        ],
                      ),
                    ),
                  )),
                  if (showPlay)
                    TvTap(
                      key: ValueKey('suggestion-play-${suggestion.keyword}'),
                      focusNode: _playFocus,
                      onTap: onPlay,
                      behavior: HitTestBehavior.opaque,
                      focusScale: 1,
                      child: const Padding(
                        padding: EdgeInsets.fromLTRB(12, 14, 24, 14),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.play_circle_outline, size: 22),
                          SizedBox(width: 6),
                          Text('播放'),
                        ]),
                      ),
                    ),
                ])),
          )),
    );
  }

  TextSpan _highlightedName(BuildContext context) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final range in suggestion.highlights) {
      final end = range.start + range.length;
      if (range.start < cursor || end > suggestion.name.length) continue;
      if (range.start > cursor) {
        spans.add(
            TextSpan(text: suggestion.name.substring(cursor, range.start)));
      }
      spans.add(TextSpan(
        text: suggestion.name.substring(range.start, end),
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      ));
      cursor = end;
    }
    spans.add(TextSpan(text: suggestion.name.substring(cursor)));
    return TextSpan(children: spans);
  }
}
