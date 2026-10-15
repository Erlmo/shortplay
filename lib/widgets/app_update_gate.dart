import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import 'app_update_dialog.dart';

/// 全局强制更新入口，覆盖所有页面；移除原页面以停止正在播放的视频。
class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({
    super.key,
    required this.service,
    required this.child,
  });

  final AppUpdateService service;
  final Widget child;

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate>
    with WidgetsBindingObserver {
  final CancelToken _cancelToken = CancelToken();
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.service.addListener(_onPolicyChanged);
    // 自动检查内部处理错误，离线时不产生未处理的 Future。
    unawaited(_check());
  }

  void _onPolicyChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _check() async {
    if (_checking || !widget.service.isSupported) return;
    _checking = true;
    try {
      await widget.service.check(cancelToken: _cancelToken);
    } catch (error) {
      // 自动检查失败时保留已知的强制更新限制，手动检查会显示错误详情。
      if (!_cancelToken.isCancelled) debugPrint('自动检查更新失败: $error');
    } finally {
      _checking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_check());
    }
  }

  @override
  void dispose() {
    _cancelToken.cancel('关闭应用更新检查');
    widget.service.removeListener(_onPolicyChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final update = widget.service.requiredUpdate;
    if (update == null) return widget.child;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: AppUpdateDialog(
            key: ValueKey('${update.version}:${update.downloadUrl}'),
            update: update,
            service: widget.service,
          ),
        ),
      ),
    );
  }
}
