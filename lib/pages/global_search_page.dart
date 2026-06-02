import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
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
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _searchController.addListener(_onSearchTextChanged);
    // 自动聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearchTextChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
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
    _loadHistory();
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('global_search_history');
    _loadHistory();
  }

  void _onSearch(String keyword) {
    if (keyword.trim().isEmpty) return;
    _addHistory(keyword.trim());
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
              child: GestureDetector(
                onTap: () {
                  if (_searchController.text.isNotEmpty) {
                    _onSearch(_searchController.text);
                  } else {
                    Navigator.pop(context);
                  }
                },
                child: Text(
                  '搜索',
                  style: TextStyle(
                    color: Theme.of(context).primaryColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
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
                  GestureDetector(
                    onTap: _clearHistory,
                    child: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Color(0xFF999999),
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
                  children: _history.map((keyword) {
                    return GestureDetector(
                      onTap: () => _onSearch(keyword),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
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
