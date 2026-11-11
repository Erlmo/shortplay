import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/app_info.dart';
import '../services/app_update_service.dart';
import '../services/device_profile.dart';
import '../services/download_service.dart';
import '../services/playback_preferences.dart';
import '../widgets/app_notice.dart';
import '../widgets/app_update_dialog.dart';
import '../widgets/favorite_drama_carousel.dart';
import 'favorite_dramas_page.dart';
import 'share_link_page.dart';
import 'tv_share_link_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.apiClient,
    this.downloadService,
    this.appUpdateService,
    this.onHomeModeChanged,
  });

  final ApiClient apiClient;
  final DownloadService? downloadService;
  final AppUpdateService? appUpdateService;
  final VoidCallback? onHomeModeChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<String> _appVersion = loadAppVersion();
  late final AppUpdateService _updates =
      widget.appUpdateService ?? AppUpdateService(apiClient: widget.apiClient);
  final CancelToken _checkCancelToken = CancelToken();
  bool _checking = false;
  bool _savingQuality = false;

  Future<void> _chooseDefaultQuality() async {
    if (_savingQuality) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('默认清晰度'),
        children: [
          for (final value in PlaybackPreferences.definitions)
            ListTile(
              title: Text(PlaybackPreferences.label(value)),
              leading: Icon(PlaybackPreferences.defaultDefinition.value == value
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              onTap: () => Navigator.of(dialogContext).pop(value),
            ),
          const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Text('视频没有所选清晰度时，使用可用档位。本地缓存和仅提供一个地址的视频按原画质播放。',
                  style: TextStyle(fontSize: 12, color: Colors.grey))),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _savingQuality = true);
    try {
      await PlaybackPreferences.save(selected);
    } catch (_) {
      if (mounted) {
        showAppNotice(context,
            message: '保存默认清晰度失败，请重试', kind: AppNoticeKind.error);
      }
    } finally {
      if (mounted) setState(() => _savingQuality = false);
    }
  }

  @override
  void dispose() {
    _checkCancelToken.cancel('关闭设置页面');
    super.dispose();
  }

  Future<void> _openShareRecognition() async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ShareLinkPage(
          apiClient: widget.apiClient, downloadService: widget.downloadService),
    ));
    if (changed == true && mounted) widget.onHomeModeChanged?.call();
  }

  Future<void> _checkForUpdates() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final update = await _updates.check(cancelToken: _checkCancelToken);
      if (!mounted) return;
      setState(() => _checking = false);
      if (update == null) {
        showAppNotice(context, message: '当前已是最新版本');
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AppUpdateDialog(update: update, service: _updates),
      );
    } catch (error) {
      if (mounted) {
        showAppNotice(context,
            message: '检查更新失败',
            detail: appUpdateError(error),
            kind: AppNoticeKind.error);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tv = DeviceProfile.isTv;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F7F7),
        body: SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  const _SettingsHeader(),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.white,
                    elevation: 0,
                    shadowColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    child: FavoriteDramaCarousel(
                      apiClient: widget.apiClient,
                      downloadService: widget.downloadService,
                      onViewAll: () =>
                          Navigator.of(context).push<void>(MaterialPageRoute(
                        builder: (_) => FavoriteDramasPage(
                            apiClient: widget.apiClient,
                            downloadService: widget.downloadService),
                      )),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.white,
                    elevation: 0,
                    shadowColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    child: Column(children: [
                      ValueListenableBuilder<String>(
                        valueListenable: PlaybackPreferences.defaultDefinition,
                        builder: (_, value, __) => _SettingsRow(
                          icon: Icons.high_quality_outlined,
                          title: '默认清晰度',
                          trailing: Text(PlaybackPreferences.label(value),
                              style: const TextStyle(
                                  fontSize: 14, color: Color(0xFF999999))),
                          onTap: _savingQuality ? null : _chooseDefaultQuality,
                        ),
                      ),
                      _divider,
                      _SettingsRow(
                        icon: tv
                            ? Icons.qr_code_scanner_rounded
                            : Icons.link_rounded,
                        title: tv ? '手机扫码播放' : '分享链接识别',
                        onTap: tv
                            ? () => Navigator.of(context)
                                    .push<void>(MaterialPageRoute(
                                  builder: (_) => TvShareLinkPage(
                                      apiClient: widget.apiClient,
                                      downloadService: widget.downloadService),
                                ))
                            : _openShareRecognition,
                      ),
                      _divider,
                      _SettingsRow(
                        icon: Icons.update_rounded,
                        title: _checking ? '正在检查更新…' : '检查更新',
                        onTap: _checking ? null : _checkForUpdates,
                        trailing: _checking
                            ? const SizedBox.square(
                                dimension: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : null,
                      ),
                      _divider,
                      _SettingsRow(
                        icon: Icons.info_outline_rounded,
                        title: '软件版本',
                        trailing: FutureBuilder<String>(
                          future: _appVersion,
                          builder: (_, snapshot) => Text(snapshot.data ?? '…',
                              style: const TextStyle(
                                  fontSize: 14, color: Color(0xFF999999))),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _divider = Divider(
      height: 1,
      thickness: 0.5,
      indent: 64,
      endIndent: 20,
      color: Color(0xFFEEEEEE));
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 32, 22, 28),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: const Color(0x14000000)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/icons/app_logo.png',
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '龙龙短剧',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF222222),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '免费好剧，随时开追',
                      style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
      minVerticalPadding: 16,
      horizontalTitleGap: 18,
      leading: Icon(icon, size: 24, color: const Color(0xFF555555)),
      title: Text(title,
          style: const TextStyle(fontSize: 16, color: Color(0xFF222222))),
      trailing: trailing ??
          const Icon(Icons.chevron_right_rounded,
              color: Color(0xFFBBBBBB), size: 20),
      onTap: onTap,
    );
  }
}
