import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../models/search_results.dart';
import '../services/device_profile.dart';
import 'tv_tap.dart';

/// 仅呈现搜索响应明确提供的 SeriesAlbum，不请求或拼接播放器合集目录。
class SearchSeriesAlbumCard extends StatefulWidget {
  const SearchSeriesAlbumCard({
    super.key,
    required this.album,
    required this.onPlay,
    this.focusNode,
  });

  final SearchSeriesAlbum album;
  final ValueChanged<Drama> onPlay;
  final FocusNode? focusNode;

  @override
  State<SearchSeriesAlbumCard> createState() => _SearchSeriesAlbumCardState();
}

class _SearchSeriesAlbumCardState extends State<SearchSeriesAlbumCard> {
  final _moreFocus = FocusNode(debugLabel: 'series-album-more');
  bool _panelOpen = false;

  @override
  void dispose() {
    _moreFocus.dispose();
    super.dispose();
  }

  Future<void> _openPanel() async {
    if (_panelOpen) return;
    _panelOpen = true;
    final selected = await showModalBottomSheet<Drama>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFFFAFAFA),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _SeriesAlbumPanel(album: widget.album),
    );
    if (!mounted) return;
    _panelOpen = false;
    if (DeviceProfile.usesFocusUi) _moreFocus.requestFocus();
    if (selected != null) widget.onPlay(selected);
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.album.preview;
    final tv = DeviceProfile.isTv;
    return SizedBox(
      width: tv ? 112 : 84,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TvTap(
          key: ValueKey('series-album-preview-${preview.id}'),
          focusNode: widget.focusNode,
          focusScale: 1,
          borderRadius: 4,
          onTap: () => widget.onPlay(preview),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: tv ? 112 : 84,
                height: tv ? 157 : 118,
                child: Stack(fit: StackFit.expand, children: [
                  _cover(preview.cover),
                  const Center(
                      child: Icon(Icons.play_circle_fill,
                          size: 20, color: Colors.white)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Text(preview.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: tv ? 16 : 13,
                    height: 1.4,
                    color: const Color(0xFF222222))),
          ]),
        ),
        TvTap(
          key: ValueKey('series-album-more-${preview.id}'),
          focusNode: _moreFocus,
          focusScale: 1,
          borderRadius: 4,
          onTap: _openPanel,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(children: [
              Expanded(
                  child: Text('共${widget.album.items.length}季',
                      maxLines: 1,
                      style: TextStyle(
                          fontSize: tv ? 15 : 12,
                          color: const Color(0xFF999999)))),
              const Icon(Icons.chevron_right,
                  size: 16, color: Color(0xFF999999)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _SeriesAlbumPanel extends StatefulWidget {
  const _SeriesAlbumPanel({required this.album});
  final SearchSeriesAlbum album;

  @override
  State<_SeriesAlbumPanel> createState() => _SeriesAlbumPanelState();
}

class _SeriesAlbumPanelState extends State<_SeriesAlbumPanel> {
  final _closeFocus = FocusNode(debugLabel: 'series-panel-close');
  late final List<FocusNode> _items = [
    for (var i = 0; i < widget.album.items.length; i++)
      FocusNode(debugLabel: 'series-panel-item-$i'),
  ];

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _items.length; i++) {
      final index = i;
      _items[i].onKeyEvent = (_, event) => _onKey(index, event);
      _items[i].addListener(() {
        final node = _items[index];
        if (node.hasPrimaryFocus && node.context != null) {
          Scrollable.ensureVisible(node.context!,
              duration: const Duration(milliseconds: 150), alignment: .5);
        }
      });
    }
    _closeFocus.onKeyEvent = (_, event) {
      if (_direction(event, LogicalKeyboardKey.arrowDown) &&
          _items.isNotEmpty) {
        _items.first.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  bool _direction(KeyEvent event, LogicalKeyboardKey key) =>
      DeviceProfile.isTv &&
      (event is KeyDownEvent || event is KeyRepeatEvent) &&
      event.logicalKey == key;

  KeyEventResult _onKey(int index, KeyEvent event) {
    if (_direction(event, LogicalKeyboardKey.arrowUp)) {
      (index == 0 ? _closeFocus : _items[index - 1]).requestFocus();
      return KeyEventResult.handled;
    }
    if (_direction(event, LogicalKeyboardKey.arrowDown)) {
      if (index + 1 < _items.length) _items[index + 1].requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _closeFocus.dispose();
    for (final node in _items) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tv = DeviceProfile.isTv;
    final title = widget.album.moduleTitle.isNotEmpty
        ? widget.album.moduleTitle
        : widget.album.preview.name;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
          child: Row(children: [
            Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: tv ? 21 : 18, fontWeight: FontWeight.w600))),
            TvTap(
              key: const ValueKey('series-album-panel-close'),
              focusNode: _closeFocus,
              autofocus: _items.isEmpty,
              focusScale: 1,
              onTap: () => Navigator.of(context).pop(),
              child: const Padding(
                  padding: EdgeInsets.all(10), child: Icon(Icons.close)),
            ),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('series-album-panel-scroll'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(children: [
              for (var index = 0; index < widget.album.items.length; index++)
                _item(widget.album.items[index], index),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _item(SearchSeriesItem item, int index) {
    final tv = DeviceProfile.isTv;
    final playable = item.isPlayable && item.drama != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TvTap(
        key: ValueKey('series-album-item-${item.key}'),
        focusNode: _items[index],
        autofocus: index == 0,
        focusScale: 1,
        borderRadius: 8,
        onTap: () {
          if (playable) Navigator.of(context).pop(item.drama);
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                    width: tv ? 58 : 48,
                    height: tv ? 81 : 67,
                    child: _cover(item.cover))),
            const SizedBox(width: 12),
            Expanded(
                child: Text(item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: tv ? 18 : 15, fontWeight: FontWeight.w500))),
            const SizedBox(width: 12),
            if (playable)
              const Icon(Icons.play_circle_outline,
                  size: 26, color: Color(0xFFFA7705))
            else
              const Text('待上线',
                  style: TextStyle(fontSize: 13, color: Color(0xFF999999))),
          ]),
        ),
      ),
    );
  }
}

Widget _cover(String url) => url.isEmpty
    ? const ColoredBox(color: Color(0xFFEAEAEA))
    : Image.network(url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const ColoredBox(color: Color(0xFFEAEAEA)));
