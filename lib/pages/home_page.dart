import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/api_client.dart';
import '../services/app_update_service.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../widgets/tv_tap.dart';
import 'cache_page.dart';
import 'home/home_feed_page.dart';
import 'play_history_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.apiClient,
    required this.downloadService,
    this.appUpdateService,
  });

  final ApiClient apiClient;
  final DownloadService downloadService;
  final AppUpdateService? appUpdateService;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  bool _tvTopBarFocused = false;
  final _homeFeedKey = GlobalKey<HomeFeedPageState>();

  late final List<Widget> _pages;

  // GlobalKey用于访问PlayHistoryPage的state，实现tab切换时刷新
  final _playHistoryKey = GlobalKey<PlayHistoryPageState>();

  @override
  void initState() {
    super.initState();
    _pages = [
      HomeFeedPage(
        key: _homeFeedKey,
        onTvTopBarFocusChanged: (focused) {
          if (mounted && focused != _tvTopBarFocused) {
            setState(() => _tvTopBarFocused = focused);
          }
        },
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
        onShowHistory: () => _selectPage(1),
      ),
      PlayHistoryPage(
        key: _playHistoryKey,
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
      ),
      CachePage(
        downloadService: widget.downloadService,
        apiClient: widget.apiClient,
      ),
      SettingsPage(
        apiClient: widget.apiClient,
        downloadService: widget.downloadService,
        appUpdateService: widget.appUpdateService,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !DeviceProfile.isTv || _currentIndex != 0 || _tvTopBarFocused,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && DeviceProfile.isTv && _currentIndex == 0) {
          _homeFeedKey.currentState?.focusCurrentTvTab();
        }
      },
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      backgroundColor:
          DeviceProfile.isTv ? const Color(0xFFF4F5F8) : Colors.white,
      body: IndexedStack(
        index: _currentIndex,
        children: _pages.indexed
            .map((entry) => ExcludeFocus(
                  excluding: entry.$1 != _currentIndex,
                  child: entry.$2,
                ))
            .toList(),
      ),
      bottomNavigationBar: DeviceProfile.isTv
          ? _buildTvNavigation()
          : Theme(
              data: ThemeData(
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
              ),
              child: BottomNavigationBar(
                currentIndex: _currentIndex,
                onTap: _selectPage,
                type: BottomNavigationBarType.fixed,
                backgroundColor: Colors.white,
                elevation: 0,
                selectedItemColor: Colors.black,
                unselectedItemColor: const Color(0xFF999999),
                selectedFontSize: 10,
                unselectedFontSize: 10,
                showSelectedLabels: true,
                showUnselectedLabels: true,
                items: [
                  _svgNavItem('home', '首页'),
                  _svgNavItem('history', '历史'),
                  _svgNavItem('cache', '缓存'),
                  const BottomNavigationBarItem(
                    icon: Icon(
                      Icons.settings_outlined,
                      size: 28,
                      color: Color(0xFF999999),
                    ),
                    activeIcon: Icon(
                      Icons.settings_rounded,
                      size: 28,
                      color: Colors.black,
                    ),
                    label: '设置',
                  ),
                ],
              ),
            ),
    );
  }

  /// 底部导航的 SVG 图标项：`assets/icons/nav_NAME.svg` 与 `nav_NAME_active.svg`。
  static BottomNavigationBarItem _svgNavItem(String name, String label) {
    return BottomNavigationBarItem(
      icon: SvgPicture.asset(
        'assets/icons/nav_$name.svg',
        width: 28,
        height: 28,
        colorFilter: const ColorFilter.mode(
          Color(0xFF999999),
          BlendMode.srcIn,
        ),
      ),
      activeIcon: SvgPicture.asset(
        'assets/icons/nav_${name}_active.svg',
        width: 28,
        height: 28,
      ),
      label: label,
    );
  }

  void _selectPage(int index) {
    setState(() => _currentIndex = index);
    // 切换到播放记录 tab 时刷新，显示最新的播放记录
    if (index == 1) _playHistoryKey.currentState?.refresh();
  }

  Widget _buildTvNavigation() {
    const labels = ['首页', '历史', '缓存', '设置'];
    const icons = [
      Icons.home_outlined,
      Icons.history_rounded,
      Icons.download_for_offline_outlined,
      Icons.settings_outlined,
    ];
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(24, 10, 24, 14),
      child: Center(
        heightFactor: 1,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE6E9EF)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(labels.length, (index) {
              final selected = index == _currentIndex;
              final color =
                  selected ? const Color(0xFFFF2442) : const Color(0xFF747B88);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: TvTap(
                  borderRadius: 16,
                  focusScale: 1,
                  onTap: () => _selectPage(index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 112,
                    height: 42,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFFFFF0F3)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icons[index], color: color, size: 21),
                        const SizedBox(width: 8),
                        Text(labels[index],
                            style: TextStyle(
                              color: color,
                              fontSize: 14,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w500,
                            )),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
