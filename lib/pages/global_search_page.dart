import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/search_suggestion.dart';
import '../services/api_client.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../widgets/search_suggestion_tile.dart';
import '../widgets/tv_search_keyboard.dart';
import '../widgets/tv_tap.dart';
import 'player_page.dart';
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
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  final _searchButtonFocusNode = FocusNode();
  final _firstResultFocusNode = FocusNode();
  final _firstHistoryFocusNode = FocusNode();
  final _backFocusNode = FocusNode();
  final _keyboardKey = GlobalKey<TvSearchKeyboardState>();
  List<String> _history = [];
  List<SearchSuggestion> _suggestions = const [];
  Timer? _suggestTimer;
  CancelToken? _suggestCancel;
  int _requestId = 0;
  String _query = '';
  String? _lastInput;
  TextRange? _lastComposing;
  bool _loadingSuggestions = false;
  bool _suggestError = false;
  bool _searchActive = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHistory());
    _searchController.addListener(_onSearchTextChanged);
    _firstResultFocusNode.onKeyEvent = _onResultKey;
    _firstHistoryFocusNode.onKeyEvent = _onResultKey;
    _searchButtonFocusNode.onKeyEvent = _onResultKey;
    _backFocusNode.onKeyEvent = (_, event) {
      if (_isDirection(event, LogicalKeyboardKey.arrowDown)) {
        _keyboardKey.currentState?.requestKeyboardFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !DeviceProfile.isTv) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _cancelSuggestions();
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    for (final node in [
      _focusNode,
      _searchButtonFocusNode,
      _firstResultFocusNode,
      _firstHistoryFocusNode,
      _backFocusNode
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  bool _isDirection(KeyEvent event, LogicalKeyboardKey key) =>
      DeviceProfile.isTv &&
      (event is KeyDownEvent || event is KeyRepeatEvent) &&
      event.logicalKey == key;

  KeyEventResult _onResultKey(FocusNode node, KeyEvent event) {
    if (_isDirection(event, LogicalKeyboardKey.arrowLeft)) {
      _keyboardKey.currentState?.requestKeyboardFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focusResults() {
    if (_query.isEmpty && _history.isNotEmpty) {
      _firstHistoryFocusNode.requestFocus();
    } else if (_suggestions.isNotEmpty) {
      _firstResultFocusNode.requestFocus();
    } else if (_query.isNotEmpty) {
      _searchButtonFocusNode.requestFocus();
    }
  }

  void _cancelSuggestions() {
    _requestId++;
    _suggestTimer?.cancel();
    _suggestTimer = null;
    _suggestCancel?.cancel();
    _suggestCancel = null;
  }

  void _onSearchTextChanged() {
    final value = _searchController.value;
    if (_lastInput == value.text && _lastComposing == value.composing) return;
    _lastInput = value.text;
    _lastComposing = value.composing;
    _cancelSuggestions();
    if (!mounted || !_searchActive) return;
    final query = value.text.trim();
    setState(() {
      _query = query;
      _suggestions = const [];
      _loadingSuggestions = query.isNotEmpty && value.composing.isCollapsed;
      _suggestError = false;
    });
    if (query.isEmpty || !value.composing.isCollapsed) return;
    // 合并连续按键；请求序号与服务端 query_key 双重校验旧响应。
    final request = _requestId;
    _suggestTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(_fetchSuggestions(query, request));
    });
  }

  Future<void> _fetchSuggestions(String query, int request) async {
    final cancel = CancelToken();
    _suggestCancel = cancel;
    try {
      final result = await widget.apiClient.fetchSearchSuggestions(
        query,
        cancelToken: cancel,
      );
      if (!mounted || request != _requestId || !_searchActive) return;
      if (result.query != query) throw ApiException('联想关键词不匹配');
      setState(() => _suggestions = result.items);
    } catch (error) {
      if (!mounted ||
          request != _requestId ||
          !_searchActive ||
          (error is DioException && CancelToken.isCancel(error))) {
        return;
      }
      setState(() => _suggestError = true);
    } finally {
      if (mounted && request == _requestId && _searchActive) {
        setState(() => _loadingSuggestions = false);
        _suggestCancel = null;
      }
    }
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _history = prefs.getStringList('global_search_history') ?? [];
    });
  }

  Future<void> _addHistory(String keyword) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('global_search_history') ?? [];
    list.remove(keyword);
    list.insert(0, keyword);
    await prefs.setStringList('global_search_history', list.take(20).toList());
    await _loadHistory();
  }

  Future<void> _clearHistory() async {
    if (DeviceProfile.isTv) _keyboardKey.currentState?.requestKeyboardFocus();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('global_search_history');
    await _loadHistory();
  }

  void _onSearch(String keyword) {
    final query = keyword.trim();
    if (query.isEmpty) return;
    unawaited(_openPage(
        query,
        SearchResultsPage(
          keyword: query,
          apiClient: widget.apiClient,
          downloadService: widget.downloadService,
        )));
  }

  void _playSuggestion(SearchSuggestion item) {
    final drama = item.drama;
    if (drama == null) return;
    unawaited(_openPage(
        item.name,
        PlayerPage(
          drama: drama,
          apiClient: widget.apiClient,
          downloadService: widget.downloadService,
          initialEpisodeIndex: 0,
        )));
  }

  Future<void> _openPage(String query, Widget page) async {
    if (!_searchActive) return;
    _searchActive = false;
    _cancelSuggestions();
    unawaited(_addHistory(query));
    _focusNode.unfocus();
    // 电视返回后继续用原首字母挑选候选，避免被选中的中文片名替换输入。
    if (!DeviceProfile.isTv) {
      _searchController.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    if (!mounted) return;
    _searchActive = true;
    _lastInput = null;
    _onSearchTextChanged();
    if (DeviceProfile.isTv) _keyboardKey.currentState?.requestKeyboardFocus();
  }

  void _clearSearchText() {
    _searchController.clear();
    if (!DeviceProfile.isTv) _focusNode.requestFocus();
  }

  void _appendInitial(String character) {
    if (_searchController.text.length >= 80) return;
    final text = _searchController.text + character;
    _searchController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _deleteInitial() {
    final text = _searchController.text;
    if (text.isEmpty) return;
    final next = String.fromCharCodes(text.runes.toList()..removeLast());
    _searchController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  KeyEventResult _onTvHardwareKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _deleteInitial();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character != null && RegExp(r'^[a-zA-Z0-9]$').hasMatch(character)) {
      _appendInitial(character.toUpperCase());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => DeviceProfile.isTv
      ? _buildTv(context)
      : Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            title: TextField(
              controller: _searchController,
              focusNode: _focusNode,
              textInputAction: TextInputAction.search,
              maxLength: 80,
              onSubmitted: _onSearch,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: '搜索短剧、作者…',
                counterText: '',
                filled: true,
                fillColor: const Color(0xFFF5F5F7),
                prefixIcon: const Icon(Icons.search, size: 19),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        onPressed: _clearSearchText,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                isDense: true,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => _onSearch(_searchController.text),
                child: const Text('搜索'),
              )
            ],
          ),
          body: _buildContent(),
        );

  Widget _buildTv(BuildContext context) => Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Focus(
            onKeyEvent: _onTvHardwareKey,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Row(children: [
                    TvTap(
                      focusNode: _backFocusNode,
                      onTap: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Text('搜索',
                        style: TextStyle(
                            fontSize: 25, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 24),
                    const Expanded(
                        child: Text('输入片名首字母，例如「万妖」输入 WY',
                            style: TextStyle(
                                fontSize: 15, color: Color(0xFF8C93A1)))),
                  ]),
                  const SizedBox(height: 18),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: (MediaQuery.sizeOf(context).width * .38)
                              .clamp(260.0, 380.0),
                          child: SingleChildScrollView(
                            child: Column(children: [
                              Container(
                                key: const ValueKey('tv-search-query'),
                                height: 52,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF7F8FA),
                                  border: Border.all(
                                      color: const Color(0xFFE9EBF0)),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(children: [
                                  const Icon(Icons.search_rounded,
                                      size: 22, color: Color(0xFF949BA8)),
                                  const SizedBox(width: 12),
                                  Expanded(
                                      child: Text(
                                          _query.isEmpty ? '首字母 / 数字' : _query,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 21,
                                              letterSpacing: 2,
                                              color: _query.isEmpty
                                                  ? const Color(0xFFA2A8B3)
                                                  : const Color(0xFF252A36)))),
                                ]),
                              ),
                              const SizedBox(height: 14),
                              TvSearchKeyboard(
                                key: _keyboardKey,
                                onInput: _appendInitial,
                                onDelete: _deleteInitial,
                                onClear: _clearSearchText,
                                onSearch: () =>
                                    _onSearch(_searchController.text),
                                onFocusResults: _focusResults,
                                onFocusBack: _backFocusNode.requestFocus,
                              ),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 28),
                        const VerticalDivider(
                            width: 1, color: Color(0xFFF0F1F4)),
                        const SizedBox(width: 24),
                        Expanded(
                            child: Focus(
                          onKeyEvent: _onResultKey,
                          child: _buildContent(),
                        )),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildContent() => _query.isEmpty
      ? _buildHistory()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(children: [
                const Expanded(
                    child: Text('搜索联想',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600))),
                if (_loadingSuggestions)
                  const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5))),
                TvTap(
                  focusNode: _searchButtonFocusNode,
                  focusScale: 1,
                  onTap: () => _onSearch(_query),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Text('搜索全部',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 14)),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: _suggestions.isNotEmpty
                  ? ListView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: _suggestions.length,
                      itemBuilder: (_, index) {
                        final item = _suggestions[index];
                        return SearchSuggestionTile(
                          key: ValueKey('suggestion-$_query-$index'),
                          suggestion: item,
                          focusNode: index == 0 ? _firstResultFocusNode : null,
                          onSearch: () => _onSearch(item.name),
                          onPlay: item.drama != null
                              ? () => _playSuggestion(item)
                              : null,
                        );
                      },
                    )
                  : _loadingSuggestions
                      ? const SizedBox.shrink()
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.search_rounded,
                                      size: 36, color: Color(0xFFD0D4DC)),
                                  const SizedBox(height: 12),
                                  Text(
                                      _suggestError
                                          ? '联想暂不可用，仍可直接搜索'
                                          : '暂无联想，试试完整片名',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Color(0xFF8C93A1),
                                          fontSize: 14)),
                                  if (_suggestError)
                                    TextButton(
                                        onPressed: () {
                                          _lastInput = null;
                                          _onSearchTextChanged();
                                        },
                                        child: const Text('重试联想')),
                                ]),
                          ),
                        ),
            ),
          ],
        );

  Widget _buildHistory() => _history.isEmpty
      ? const Center(
          child: Text('输入片名或首字母，寻找想看的短剧',
              style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))))
      : ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              const Expanded(
                  child: Text('历史记录',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600))),
              TvTap(
                onTap: () => unawaited(_clearHistory()),
                child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.delete_outline,
                        size: 20, color: Color(0xFF999999))),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 12,
              children: _history.indexed
                  .map((entry) => TvTap(
                        focusNode:
                            entry.$1 == 0 ? _firstHistoryFocusNode : null,
                        borderRadius: 12,
                        onTap: () => _onSearch(entry.$2),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: DeviceProfile.isTv ? 12 : 8),
                          decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F7),
                              borderRadius: BorderRadius.circular(12)),
                          child: Text(entry.$2,
                              style: TextStyle(
                                  fontSize: DeviceProfile.isTv ? 15 : 13,
                                  color: const Color(0xFF616978))),
                        ),
                      ))
                  .toList(),
            ),
          ],
        );
}
