import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/app_info.dart';
import '../services/app_update_service.dart';
import '../services/download_service.dart';
import '../services/device_profile.dart';
import '../widgets/tv_tap.dart';
import '../widgets/app_notice.dart';
import '../widgets/app_update_dialog.dart';
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

  Widget _buildTvSettings() {
    return SafeArea(
      bottom: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
            children: [
              const Text('设置',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF242833))),
              const SizedBox(height: 6),
              const Text('应用与版本',
                  style: TextStyle(fontSize: 13, color: Color(0xFF747B88))),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20)),
                child: Row(children: [
                  ClipRRect(
                      borderRadius: BorderRadius.circular(13),
                      child: Image.asset('assets/icons/app_logo.png',
                          width: 52, height: 52)),
                  const SizedBox(width: 16),
                  const Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('龙龙短剧',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF242833))),
                        SizedBox(height: 5),
                        Text('免费好剧，随时开追',
                            style: TextStyle(
                                fontSize: 13, color: Color(0xFF747B88))),
                      ])),
                  FutureBuilder<String>(
                      future: _appVersion,
                      builder: (_, snapshot) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                              color: const Color(0xFFF4F5F8),
                              borderRadius: BorderRadius.circular(10)),
                          child: Text(snapshot.data ?? '…',
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFF747B88))))),
                ]),
              ),
              const SizedBox(height: 20),
              _TvSettingsRow(
                  icon: Icons.qr_code_scanner_rounded,
                  title: '手机扫码播放',
                  subtitle: '手机扫码输入分享链接，电视识别后播放',
                  onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                          builder: (_) => TvShareLinkPage(
                              apiClient: widget.apiClient,
                              downloadService: widget.downloadService)))),
              const SizedBox(height: 12),
              _TvSettingsRow(
                  icon: Icons.update_rounded,
                  title: _checking ? '正在检查更新…' : '检查更新',
                  subtitle: '获取最新版本，体验更多改进',
                  onTap: _checkForUpdates,
                  trailing: _checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : null),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: DeviceProfile.isTv
            ? const Color(0xFFF4F5F8)
            : const Color(0xFFF7F7F7),
        body: DeviceProfile.isTv
            ? _buildTvSettings()
            : ListView(
                padding: EdgeInsets.zero,
                children: [
                  const _SettingsHeader(),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.white,
                    child: Column(
                      children: [
                        _SettingsRow(
                          icon: Icons.link_rounded,
                          title: '分享链接识别',
                          onTap: _openShareRecognition,
                        ),
                        const Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 64,
                          endIndent: 20,
                          color: Color(0xFFEEEEEE),
                        ),
                        _SettingsRow(
                          icon: Icons.update_rounded,
                          title: _checking ? '正在检查更新…' : '检查更新',
                          onTap: _checking ? null : _checkForUpdates,
                        ),
                        const Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 64,
                          endIndent: 20,
                          color: Color(0xFFEEEEEE),
                        ),
                        _SettingsRow(
                          icon: Icons.info_outline_rounded,
                          title: '软件版本',
                          trailing: FutureBuilder<String>(
                            future: _appVersion,
                            builder: (_, snapshot) => Text(
                              snapshot.data ?? '…',
                              style: const TextStyle(
                                  fontSize: 14, color: Color(0xFF999999)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 设置页头部：白底，真实应用图标 + 名称 + 一句文案，不放“设置”标题。
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

class _TvSettingsRow extends StatelessWidget {
  const _TvSettingsRow(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap,
      this.trailing});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return TvTap(
      borderRadius: 16,
      focusScale: 1,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE6E9EF))),
        child: Row(children: [
          Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: const Color(0xFFFFF0F3),
                  borderRadius: BorderRadius.circular(13)),
              child: Icon(icon, size: 24, color: const Color(0xFFFF2442))),
          const SizedBox(width: 16),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF242833))),
                const SizedBox(height: 5),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF747B88))),
              ])),
          trailing ??
              const Icon(Icons.chevron_right_rounded, color: Color(0xFFA4AAB5)),
        ]),
      ),
    );
  }
}
