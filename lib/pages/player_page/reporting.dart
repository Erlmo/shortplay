part of '../player_page.dart';

/// 五秒是本 APP 的持久化/尝试发送节奏；APK 证据中的五秒仅指本地进度采样。
const _watchCheckpointInterval = Duration(seconds: 5);

extension _PlayerReporting on _PlayerPageState {
  String? _watchItemId() {
    if (_episodes.isEmpty || _currentEpisodeIndex >= _episodes.length) {
      return null;
    }
    final episode = _episodes[_currentEpisodeIndex];
    if (!isOfflinePlayback) {
      return PlaybackReportBook.validId(episode.url) ? episode.url : null;
    }
    final group = widget.downloadService?.groups[_drama.id.toString()];
    if (group == null) return null;
    for (final download in group.episodes) {
      if (download.episode.index == episode.index &&
          download.localPath == episode.url &&
          PlaybackReportBook.validId(download.episode.url)) {
        return download.episode.url;
      }
    }
    // 本地文件路径不能用作上游视频 ID，缺少映射时保留本地历史即可。
    return null;
  }

  void _beginWatchSession(NativePlayer player, int? initialSeekMs) {
    final bookId = _drama.id.toString();
    final itemId = _watchItemId();
    if (!PlaybackReportBook.validId(bookId) || itemId == null) return;
    _watchSeeking = false;
    _watchTailCheckpointed = false;
    _watchSession = PlaybackReportSession(
      bookId: bookId,
      itemId: itemId,
      vidIndex: _episodes[_currentEpisodeIndex].index,
      queue: widget.apiClient.playbackReports,
      initialPositionMs: initialSeekMs ?? player.position.inMilliseconds,
    );
    if (initialSeekMs != null && initialSeekMs > 0) {
      _watchSession!.seek(initialSeekMs);
    }
    _syncWatchState();
    unawaited(widget.apiClient.playbackReports.flush());
  }

  void _sampleWatchPosition() {
    final player = _player;
    if (player != null) _watchSession?.position(player.position.inMilliseconds);
  }

  void _syncWatchState() {
    final session = _watchSession;
    if (session == null) return;
    final player = _player;
    final playing = player != null &&
        player.playing &&
        _playerInitialized &&
        !_sleepStopped &&
        !_userPaused;
    session.update(
      playing: playing,
      buffering: player?.buffering ?? true,
      foreground: _watchForeground,
      visible: _watchVisible,
      seeking: _watchSeeking,
      rate: _effectiveRate,
    );
    final active = playing &&
        !player.buffering &&
        _watchForeground &&
        _watchVisible &&
        !_watchSeeking;
    if (active) {
      _watchCheckpointTimer ??= Timer.periodic(_watchCheckpointInterval, (_) {
        _sampleWatchPosition();
        _checkpointWatch();
      });
    } else {
      _watchCheckpointTimer?.cancel();
      _watchCheckpointTimer = null;
    }
  }

  void _checkpointWatch() {
    final session = _watchSession;
    if (session == null) return;
    unawaited(() async {
      try {
        await session.checkpoint();
        await widget.apiClient.playbackReports.flush();
      } catch (error) {
        debugPrint('保存观看记录失败，下次观看时重试');
      }
    }());
  }

  void _finishWatchSession({int? finalPositionMs}) {
    _sampleWatchPosition();
    final session = _watchSession;
    if (finalPositionMs != null) session?.position(finalPositionMs);
    _watchSession = null;
    _watchCheckpointTimer?.cancel();
    _watchCheckpointTimer = null;
    if (session == null) return;
    unawaited(() async {
      try {
        await session.checkpoint(close: true);
        await widget.apiClient.playbackReports.flush();
      } catch (error) {
        debugPrint('保存离开播放页的观看记录失败');
      }
    }());
  }
}
