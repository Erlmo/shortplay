import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../widgets/tv_tap.dart';
import 'search_results_page.dart';

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({
    super.key,
    required this.apiClient,
    this.downloadService,
  });
  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final FocusNode _searchButtonFocusNode = FocusNode();
  final FocusNode _firstHistoryFocusNode = FocusNode();
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadHistory());
    _focusNode.onKeyEvent = _onInputKeyEvent;
    _searchButtonFocusNode.onKeyEvent = _onSearchButtonKeyEvent;
    _searchController.addListener(_onSearchTextChanged);
    // 自动聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _focusNode.dispose();
    _searchButtonFocusNode.dispose();
    _firstHistoryFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onInputKeyEvent(FocusNode node, KeyEvent event) {
    if (!DeviceProfile.isTv ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final value = _searchController.value;
    // 输入法仍在组词时保留方向键，提交文字后再切换控件。
    if (!value.composing.isCollapsed) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      (_history.isEmpty ? _searchButtonFocusNode : _firstHistoryFocusNode)
          .requestFocus();
      return KeyEventResult.handled;
    }
    final atEnd = value.text.isEmpty ||
        (value.selection.isValid &&
            value.selection.isCollapsed &&
            value.selection.extentOffset == value.text.length);
    // 文本内部仍用左右键编辑；光标到末尾后，右键移到搜索按钮。
    if (event.logicalKey == LogicalKeyboardKey.arrowRight && atEnd) {
      _searchButtonFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onSearchButtonKeyEvent(FocusNode node, KeyEvent event) {
    if (!DeviceProfile.isTv ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _focusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
        _history.isNotEmpty) {
      _firstHistoryFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onSearchTextChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _history = prefs.getStringList('global_search_history') ?? [];
    });
  }

  Future<void> _addHistory(String keyword) async {
    if (keyword.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('global_search_history') ?? [];

    // 去重并移动到最前
    list.remove(keyword);
    list.insert(0, keyword);

    // 限制长度
    if (list.length > 20) {
      list.removeLast();
    }

    await prefs.setStringList('global_search_history', list);
    await _loadHistory();
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('global_search_history');
    await _loadHistory();
  }

  void _onSearch(String keyword) {
    if (keyword.trim().isEmpty) return;
    unawaited(_addHistory(keyword.trim()));
    _focusNode.unfocus();
    _searchController.text = keyword.trim();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SearchResultsPage(
          keyword: keyword.trim(),
          apiClient: widget.apiClient,
          downloadService: widget.downloadService,
        ),
      ),
    );
  }

  void _clearSearchText() {
    _searchController.clear();
    _focusNode.requestFocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new,
            color: Colors.black,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Container(
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(18),
          ),
          child: TextField(
            controller: _searchController,
            focusNode: _focusNode,
            textInputAction: TextInputAction.search,
            onSubmitted: _onSearch,
            style: const TextStyle(fontSize: 14, color: Colors.black),
            decoration: InputDecoration(
              hintText: '搜索短剧、作者...',
              hintStyle: const TextStyle(
                fontSize: 14,
                color: Color(0xFF999999),
              ),
              prefixIcon: const Icon(
                Icons.search,
                color: Color(0xFF999999),
                size: 18,
              ),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      onPressed: _clearSearchText,
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Color(0xFF999999),
                        size: 18,
                      ),
                      splashRadius: 18,
                      tooltip: '清除',
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              isDense: true,
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: TvTap(
                borderRadius: 10,
                focusScale: 1,
                focusNode: _searchButtonFocusNode,
                onTap: () {
                  if (_searchController.text.isNotEmpty) {
                    _onSearch(_searchController.text);
                  } else if (!DeviceProfile.isTv) {
                    Navigator.pop(context);
                  }
                },
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: DeviceProfile.isTv ? 16 : 0,
                    vertical: DeviceProfile.isTv ? 10 : 0,
                  ),
                  child: Text('搜索',
                      style: TextStyle(
                        color: Theme.of(context).primaryColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_history.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '历史记录',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF333333),
                    ),
                  ),
                  TvTap(
                    borderRadius: 9,
                    onTap: () {
                      if (DeviceProfile.isTv) {
                        _searchButtonFocusNode.requestFocus();
                      }
                      unawaited(_clearHistory());
                    },
                    child: Padding(
                      padding: EdgeInsets.all(DeviceProfile.isTv ? 10 : 0),
                      child: const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: Color(0xFF999999),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _history.indexed.map((entry) {
                    final keyword = entry.$2;
                    return TvTap(
                      focusNode: entry.$1 == 0 ? _firstHistoryFocusNode : null,
                      borderRadius: 16,
                      onTap: () => _onSearch(keyword),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: DeviceProfile.isTv ? 10 : 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          keyword,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF666666),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
