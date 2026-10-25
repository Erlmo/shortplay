import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../models/drama_season.dart';
import '../models/episode.dart';
import '../services/api_client.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../services/playback_history_store.dart';
import '../services/theater_video_preload_manager.dart';
import '../widgets/app_notice.dart';
import '../widgets/detail_action_bar.dart';
import '../widgets/detail_episode_strip.dart';
import '../widgets/episode_selector.dart';
import '../widgets/expandable_synopsis.dart';
import '../widgets/related_seasons.dart';
import '../widgets/tv_drama_detail_view.dart';
import '../widgets/tv_tap.dart';
import 'player_page.dart';

part 'drama_detail_page/actions.dart'; // 数据加载与播放 / 缓存操作
part 'drama_detail_page/phone_layout.dart'; // 手机竖屏布局
part 'drama_detail_page/wide_layout.dart'; // 电视 / 桌面宽屏布局

class DramaDetailPage extends StatefulWidget {
  const DramaDetailPage({
    super.key,
    required this.drama,
    required this.apiClient,
    this.downloadService,
  });

  final Drama drama;
  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  State<DramaDetailPage> createState() => _DramaDetailPageState();
}

class _DramaDetailPageState extends State<DramaDetailPage> {
  Drama? _detailDrama;
  bool _isLoading = true;
  bool _addingDownloads = false;
  int? _lastEpisodeIndex;
  int? _lastPositionMs;
  final CancelToken _seasonsCancelToken = CancelToken();
  DramaSeasons? _seasons;
  bool _loadingSeasons = false;
  bool _seasonsFailed = false;

  /// 进详情页就后台发起的剧集列表请求，进播放页时复用，省掉首集那次 App 接口往返。
  Future<TheaterEpisodesResult>? _prefetchedEpisodes;

  /// 详情页预热首集播放地址 + 512KB seed 用的预加载器。late 是因为要用 widget
  /// 的 apiClient 构造，在 initState 里初始化。
  late final TheaterVideoPreloadManager _detailPreloadManager =
      TheaterVideoPreloadManager(apiClient: widget.apiClient);

  Drama get drama => _detailDrama ?? widget.drama;
  ApiClient get apiClient => widget.apiClient;

  @override
  void initState() {
    super.initState();
    _loadDramaDetail();
    _loadHistory();
    _prefetchEpisodes();
    if (widget.drama.isTheaterResource) unawaited(_loadSeasons());
    PlaybackHistoryStore.revision.addListener(_onHistoryChanged);
  }

  // 播放页退出时才写入最终进度（晚于路由返回），收到变更再刷新续播信息。
  void _onHistoryChanged() => unawaited(_loadHistory());

  @override
  void dispose() {
    PlaybackHistoryStore.revision.removeListener(_onHistoryChanged);
    _seasonsCancelToken.cancel('详情页已关闭');
    super.dispose();
  }

  /// 供 part 文件里的 extension 刷新界面（setState 是 protected，extension 不能直接调）。
  void _refresh([VoidCallback? fn]) => setState(fn ?? () {});

  @override
  Widget build(BuildContext context) {
    // 设置状态栏样式
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    final size = MediaQuery.of(context).size;

    // 加载中显示指示器
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CupertinoActivityIndicator(radius: 12)),
      );
    }

    // 加载失败或无数据（仅剧场资源需要加载详情）
    if (_detailDrama == null && widget.drama.isTheaterResource) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.black,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                '加载失败',
                style: TextStyle(color: Colors.grey[600], fontSize: 16),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                  });
                  _loadDramaDetail();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF2E55),
                  foregroundColor: Colors.white,
                ),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (DeviceProfile.usesFocusUi && size.width > size.height) {
      return _buildWideLayout(context);
    }

    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: _buildImmersiveActions(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        cacheExtent: DeviceProfile.usesFocusUi ? 3000 : null,
        slivers: [
          _buildSliverAppBar(context, size),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList(
                delegate: SliverChildListDelegate([
              _buildImmersiveHeader(),
              if (drama.intro.isNotEmpty) ...[
                const SizedBox(height: 8),
                ExpandableSynopsis(
                    key: ValueKey('synopsis-${drama.id}'),
                    text: drama.intro,
                    showHeading: false,
                    initiallyExpanded: true),
              ],
              if (_prefetchedEpisodes != null) ...[
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1, color: Color(0xFFF3F4F6))),
                _buildCompactEpisodes(),
              ],
            ])),
          ),
        ],
      ),
    );
  }
}
