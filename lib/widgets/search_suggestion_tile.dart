import 'package:flutter/material.dart';

import '../models/search_suggestion.dart';
import '../services/device_profile.dart';
import 'tv_tap.dart';

class SearchSuggestionTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final tv = DeviceProfile.isTv;
    final rich = suggestion.isRich && suggestion.cover.isNotEmpty;
    final directPlay = onPlay != null;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tv ? 3 : 12, vertical: 4),
      child: Material(
        color: rich ? const Color(0xFFF7F8FA) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: TvTap(
          focusNode: focusNode,
          borderRadius: 14,
          focusScale: 1,
          onTap: directPlay ? onPlay : onSearch,
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
                        child: Icon(Icons.movie_outlined, color: Colors.grey),
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
                          fontWeight: rich ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      if (rich) ...[
                        const SizedBox(height: 6),
                        Text(
                          suggestion.drama?.subTitle?.isNotEmpty == true
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
                  directPlay
                      ? Icons.play_circle_outline
                      : Icons.north_west_rounded,
                  size: 19,
                  color: const Color(0xFFB2B7C1),
                ),
              ],
            ),
          ),
        ),
      ),
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
