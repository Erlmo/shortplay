import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/favorite_drama_store.dart';
import '../widgets/app_notice.dart';
import '../widgets/favorite_drama_carousel.dart';

class FavoriteDramasPage extends StatefulWidget {
  const FavoriteDramasPage(
      {super.key, required this.apiClient, this.downloadService});
  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  State<FavoriteDramasPage> createState() => _FavoriteDramasPageState();
}

class _FavoriteDramasPageState extends State<FavoriteDramasPage> {
  List<Drama> _items = [];
  final Set<String> _selected = {};
  bool _managing = false;
  bool _busy = false;

  void _onItemsChanged(List<Drama> items) {
    if (!mounted) return;
    setState(() {
      _items = items;
      _selected.retainAll(items.map(FavoriteDramaStore.keyOf));
      if (items.isEmpty) _managing = false;
    });
  }

  void _toggleManagement() {
    if (_busy) return;
    setState(() {
      _managing = !_managing;
      _selected.clear();
    });
  }

  void _select(Drama drama) {
    if (_busy) return;
    final key = FavoriteDramaStore.keyOf(drama);
    setState(() {
      if (!_selected.add(key)) _selected.remove(key);
    });
  }

  Future<void> _removeSelected() async {
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      await FavoriteDramaStore.removeMany(_selected);
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _managing = false;
      });
    } catch (_) {
      if (mounted) {
        showAppNotice(context,
            message: '取消收藏失败，请重试', kind: AppNoticeKind.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_managing && !_busy,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _managing && !_busy) _toggleManagement();
        },
        child: Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            title: const Text('全部收藏'),
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            actions: [
              if (_items.isNotEmpty)
                TextButton(
                    onPressed: _busy ? null : _toggleManagement,
                    child: Text(_managing ? '完成' : '管理')),
              const SizedBox(width: 8),
            ],
          ),
          body: FavoriteDramaCarousel(
            apiClient: widget.apiClient,
            downloadService: widget.downloadService,
            showAll: true,
            managing: _managing,
            selectedKeys: Set.unmodifiable(_selected),
            onSelect: _select,
            onItemsChanged: _onItemsChanged,
          ),
          bottomNavigationBar: !_managing
              ? null
              : SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 16, 12),
                    child: Row(children: [
                      TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                    if (_selected.length == _items.length) {
                                      _selected.clear();
                                    } else {
                                      _selected.addAll(
                                          _items.map(FavoriteDramaStore.keyOf));
                                    }
                                  }),
                          child: Text(_selected.length == _items.length
                              ? '取消全选'
                              : '全选')),
                      Expanded(
                        child: Text('已选 ${_selected.length} 部',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      FilledButton(
                          onPressed: _busy || _selected.isEmpty
                              ? null
                              : _removeSelected,
                          child: Text(_busy ? '处理中…' : '取消收藏')),
                    ]),
                  )),
        ),
      );
}
