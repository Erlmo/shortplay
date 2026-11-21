part of '../player_page.dart';

/// 剧集页的 UI：竖向 PageView、每一页的画面 / 弹幕 / 控件叠加层。
extension _PlayerView on _PlayerPageState {
  Widget _buildPageView() {
    // 随时可以翻页：命中预渲染就秒开，没命中就新建播放器加载。
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 最后一集继续上滑：拖过阈值就进入下一季（此时是回弹物理，越界体现在 pixels 上）
        if (notification is ScrollUpdateNotification &&
            notification.depth == 0 &&
            notification.dragDetails != null &&
            notification.metrics.pixels - notification.metrics.maxScrollExtent >
                _kSeasonSwipeThreshold &&
            _canAdvanceSeason) {
          unawaited(_advanceToNextSeason());
          return false;
        }
        return false;
      },
      child: PageView.builder(
        key: ValueKey('player-pages-${_drama.id}'),
        controller: _pageController,
        scrollDirection: Axis.vertical,
        physics: _sleepStopped || _isDirectVideo
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        onPageChanged: _onPageChanged,
        itemCount: _episodes.length,
        itemBuilder: (context, index) => _buildEpisodePage(index),
      ),
    );
  }

  /// 第 [index] 页显示哪个播放器的画面：当前集，或预渲染好的相邻集（拖动时就能看到真实首帧）。
  NativePlayer? _pagePlayerFor(int index) {
    if (index == _currentEpisodeIndex) return _player;
    if (index == standbyIndex && standbyReady) return standbyPlayer;
    if (index == parkedIndex) return parkedPlayer;
    return null;
  }

  // 视频尺寸由原生异步上报：尺寸一到就重建这一页（画面缩放 + 横屏按钮），
  // 不等下一次无关的 setState，避免横屏片源先按 9:16 被拉伸一会儿。
  Widget _buildEpisodePage(int index) {
    final pagePlayer = _pagePlayerFor(index);
    if (pagePlayer == null) return _buildEpisodePageContent(index);
    return ValueListenableBuilder<Size>(
      valueListenable: pagePlayer.videoSizeNotifier,
      builder: (context, _, __) => _buildEpisodePageContent(index),
    );
  }

  /// 选集面板打开时把画面（竖屏可见区域）等比缩到面板上方、贴着状态栏下沿。
  Widget _shrinkable(Widget video) {
    return AnimatedBuilder(
      animation: _episodeShrink,
      child: video,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_episodeShrink.value);
        if (t == 0) return child!;
        final media = MediaQuery.of(context);
        final size = media.size;
        final top = media.viewPadding.top;
        final fills = PlayerVideoSurface.usesPhoneLayout(size, false);
        // 竖屏时画面可见区域在底部选集栏之上
        final areaH = fills
            ? size.height - PlayerVideoSurface.phoneBottomBarHeight
            : size.height;
        final panelH =
            _shrinkPanelHeight ?? size.height * kHgEpisodePanelHeightFactor;
        final targetH = size.height - panelH - top - 8;
        final scale = (targetH / areaH).clamp(0.2, 1.0);
        final s = 1 - (1 - scale) * t;
        return Transform(
          alignment: Alignment.topCenter,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, top * t, 0.0, 1.0)
            ..scaleByDouble(s, s, 1.0, 1.0),
          child: child,
        );
      },
    );
  }

  /// 红果：选集面板打开时隐藏弹幕和控件，只留缩小的画面。
  Widget _hideWhileShrunk(Widget child) => AnimatedBuilder(
        animation: _episodeShrink,
        child: child,
        builder: (context, child) {
          final v = _episodeShrink.value;
          if (v == 0) return child!;
          return IgnorePointer(
            child: Opacity(opacity: (1 - v * 2).clamp(0.0, 1.0), child: child),
          );
        },
      );

  Widget _buildEpisodePageContent(int index) {
    final isActive = index == _currentEpisodeIndex;
    final pagePlayer = _pagePlayerFor(index);
    final textureId = pagePlayer?.textureId;
    // 没有播放器画面时，用这一集离开时截下的画面顶上，往回滑看起来像没离开过。
    final snapshot = textureId == null ? snapshotOf(index) : null;
    final hasTexture = textureId != null || snapshot != null;

    final videoWidget = textureId != null
        ? PlayerVideoSurface(
            textureId: textureId,
            videoWidth: pagePlayer!.videoWidth,
            videoHeight: pagePlayer.videoHeight,
            isLandscapeFullScreen: _systemUi.isLandscapeFullScreen,
            fillScreen: _landscapeFill,
          )
        : snapshot != null
            ? PlayerVideoSurface(
                snapshot: snapshot.bytes,
                videoWidth: snapshot.width,
                videoHeight: snapshot.height,
                isLandscapeFullScreen: _systemUi.isLandscapeFullScreen,
                fillScreen: _landscapeFill,
              )
            : const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        if (hasTexture) isActive ? _shrinkable(videoWidget) : videoWidget,
        if (isActive && hasTexture && !_isDirectVideo)
          _hideWhileShrunk(_buildDanmaku(index)),
        if (isActive && _loading && snapshot == null)
          const Center(
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 2,
            ),
          ),
        if (isActive && _errorMessage != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTapVideo,
            // 竖屏不挂双击：否则单击要等双击判定（约 300ms）才响应
            onDoubleTap:
                _systemUi.isLandscapeFullScreen ? _onDoubleTapVideo : null,
            onLongPressStart: _onLongPressStart,
            onLongPressEnd: _onLongPressEnd,
            child: Container(color: Colors.transparent),
          ),
        ),
        // 电视 / 桌面：叠加层按钮不参与焦点，遥控器按键统一由播放页处理
        // （否则焦点落到倍速/更多按钮上，OK 会直接点它们）。鼠标点击不受影响。
        if (isActive)
          _hideWhileShrunk(DeviceProfile.usesFocusUi
              ? ExcludeFocus(child: _buildControlsOverlay(index))
              : _buildControlsOverlay(index)),
      ],
    );
  }

  Widget _buildDanmaku(int index) {
    return ListenableBuilder(
      listenable: Listenable.merge([_danmakuController, playingNotifier]),
      builder: (context, _) => DanmakuLayer(
        key: ValueKey('danmaku-${_episodes[index].url}'),
        seekGeneration: _danmakuSeekGeneration,
        comments: _danmakuController.comments,
        getPositionMs: () => positionMsNotifier.value,
        isPlaying: playingNotifier.value,
        visible: _danmakuController.enabled,
        playbackSpeed: _effectiveRate,
        topOffset: MediaQuery.viewPaddingOf(context).top +
            (MediaQuery.orientationOf(context) == Orientation.landscape
                ? 8
                : 64),
      ),
    );
  }

  Widget _buildControlsOverlay(int index) {
    final videoId = _episodes[index].url.trim();
    return PlayerControlsOverlay(
      player: null,
      isDirectVideo: _isDirectVideo,
      isLiked: _isLiked,
      onLikeTap: (!_isDirectVideo && _drama.id != 0) ||
              (_isDirectVideo && widget.directVideoMetadata != null)
          ? () => unawaited(_toggleLike())
          : null,
      playerInitialized: _playerInitialized,
      isLandscapeFullScreen: _systemUi.isLandscapeFullScreen,
      showLandscapeUI: _systemUi.showLandscapeUI,
      isVideoFilled: _landscapeFill,
      onToggleVideoFit: _onToggleVideoFit,
      isPageTransitioning: false,
      isOfflinePlayback: isOfflinePlayback,
      isTheaterResource: _drama.isTheaterResource,
      danmakuEnabled: _danmakuController.enabled,
      isSpeedUp: _isSpeedUp,
      userPaused: _userPaused,
      currentEpisodeIndex: _currentEpisodeIndex,
      playbackSpeed: _playbackSpeed,
      positionMsNotifier: positionMsNotifier,
      playingNotifier: playingNotifier,
      speedButtonKey: speedButtonKey,
      seekingPositionMs: _seekingPositionMs,
      durationMsNotifier: durationMsNotifier,
      videoWidth: _player?.videoWidth ?? 0,
      videoHeight: _player?.videoHeight ?? 0,
      onBack: _onBack,
      onToggleDanmaku: _onToggleDanmaku,
      onSpeedTap: _onSpeedTap,
      onSpeedChanged: _onSpeedChanged,
      onEpisodeTap: _onEpisodeTap,
      episodeNumber: _episodes[index].index,
      dramaName: _drama.name,
      totalEpisodes: _episodes.length,
      dramaTags: _drama.tags,
      dramaIntro: _drama.intro,
      onNextEpisode:
          _currentEpisodeIndex < _episodes.length - 1 || _canAdvanceSeason
              ? () => _stepEpisode(1)
              : null,
      canDownload: _canDownload && _episodes.isNotEmpty,
      sleepTimerActive: _sleepTimer.isActive,
      currentQuality: (_isDirectVideo || isOfflinePlayback)
          ? ''
          : _preloadManager.selectedDefinition(videoId),
      loadQualities: (_isDirectVideo || isOfflinePlayback)
          ? null
          : () => _preloadManager.availableDefinitions(videoId),
      onQualityChanged: _onQualityChanged,
      onSleepDurationChanged: _onSleepDurationChanged,
      sleepTimerMinutes: _sleepTimer.isActive ? _sleepTimerMinutes : null,
      onMenuAction: _onMenuAction,
      onMenuOpened: () => _systemUi.setMenuOpen(true),
      onMenuClosed: () => _systemUi.setMenuOpen(false),
      onBottomPanelHeight: _onBottomPanelHeight,
      onTogglePlay: _onTogglePlay,
      onToggleLandscapeFullScreen: _onToggleLandscapeFullScreen,
      onSeekStart: _onSeekStart,
      onSeekChanged: _onSeekChanged,
      onSeekEnd: _onSeekEnd,
    );
  }
}
