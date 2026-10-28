import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_update.dart';
import '../services/app_update_service.dart';

class AndroidAppUpdateDialog extends StatefulWidget {
  const AndroidAppUpdateDialog(
      {super.key, required this.update, required this.service});
  final AppUpdate update;
  final AppUpdateService service;

  @override
  State<AndroidAppUpdateDialog> createState() => _AndroidAppUpdateDialogState();
}

class _AndroidAppUpdateDialogState extends State<AndroidAppUpdateDialog>
    with WidgetsBindingObserver {
  final _primaryFocus = FocusNode(debugLabel: '安卓更新主要操作');
  CancelToken? _cancel;
  String? _apk;
  String? _error;
  String _status = '在应用内下载并安装，无需浏览器';
  int _received = 0;
  int _total = 0;
  bool _downloading = false;
  bool _installing = false;
  bool _waitingPermission = false;
  bool _installerOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _waitingPermission &&
        !_installing) {
      unawaited(_continueAfterPermission());
    }
  }

  Future<void> _continueAfterPermission() async {
    try {
      if (await widget.service.canInstallApks() &&
          mounted &&
          _waitingPermission) {
        await _install();
      }
    } catch (error) {
      if (mounted) setState(() => _error = appUpdateError(error));
    }
  }

  Future<void> _download() async {
    final cancel = CancelToken();
    _cancel = cancel;
    setState(() {
      _error = null;
      _downloading = true;
      _received = 0;
      _total = 0;
      _status = '正在下载安装包…';
    });
    try {
      final path = await widget.service.downloadApk(
        widget.update,
        cancelToken: cancel,
        onProgress: (received, total) {
          if (!mounted || cancel.isCancelled) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        _apk = path;
        _downloading = false;
      });
      await _install();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (error is DioException && CancelToken.isCancel(error)) {
          _status = '下载已取消，可以重新下载';
        } else {
          _error = appUpdateError(error);
          _status = '下载未完成，请重试';
        }
      });
    } finally {
      if (mounted) {
        setState(() => _downloading = false);
        _primaryFocus.requestFocus();
      }
    }
  }

  Future<void> _install() async {
    if (_apk == null || _installing) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      final status = await widget.service.installApk(_apk!);
      if (!mounted) return;
      setState(() {
        _waitingPermission = status == 'permission_required';
        _installerOpened = status == 'installer_opened';
        _status =
            _waitingPermission ? '请允许“龙龙短剧”安装应用，然后按返回键继续安装' : '已打开系统安装界面，请确认安装';
      });
    } catch (error) {
      if (!mounted) return;
      if (error is PlatformException &&
          ['INVALID_APK', 'WRONG_APP', 'WRONG_SIGNATURE', 'NOT_NEWER']
              .contains(error.code)) {
        final invalid = _apk;
        _apk = null;
        if (invalid != null) {
          try {
            await File(invalid).delete();
          } on FileSystemException {/* 文件可能已被系统清理。 */}
        }
      }
      if (mounted) setState(() => _error = appUpdateError(error));
    } finally {
      if (mounted) {
        setState(() => _installing = false);
        _primaryFocus.requestFocus();
      }
    }
  }

  void _cancelDownload() => _cancel?.cancel('用户取消下载');

  @override
  void dispose() {
    _cancel?.cancel('关闭更新窗口');
    WidgetsBinding.instance.removeObserver(this);
    _primaryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    final buttonText = _downloading
        ? '取消下载'
        : _installing
            ? '正在准备安装…'
            : _waitingPermission
                ? '允许安装并继续'
                : _apk != null
                    ? (_installerOpened ? '再次安装' : '立即安装')
                    : _error != null
                        ? '重新下载'
                        : '下载并安装';
    return PopScope(
      canPop: !widget.update.isRequired && !_downloading && !_installing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _downloading) _cancelDownload();
      },
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: AlertDialog(
          title: Text(
              '${widget.update.isRequired ? '需要更新至' : '发现新版本'} ${widget.update.version}'),
          scrollable: true,
          content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.update.releaseNotes.trim().isEmpty
                      ? '修复问题并改善使用体验'
                      : widget.update.releaseNotes),
                  const SizedBox(height: 20),
                  if (_downloading) ...[
                    LinearProgressIndicator(value: progress, minHeight: 8),
                    const SizedBox(height: 10),
                    Text(
                        _total > 0
                            ? '${(progress! * 100).toStringAsFixed(0)}%  ·  ${(_received / 1048576).toStringAsFixed(1)} / ${(_total / 1048576).toStringAsFixed(1)} MB'
                            : '已下载 ${(_received / 1048576).toStringAsFixed(1)} MB',
                        key: const ValueKey('tv-update-progress')),
                    const SizedBox(height: 12),
                  ],
                  Text(_status),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: colors.error)),
                  ],
                ],
              )),
          actions: [
            if (!widget.update.isRequired && !_downloading && !_installing)
              FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: TextButton(
                    style: _focusStyle(context),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('稍后'),
                  )),
            FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: FilledButton(
                  key: const ValueKey('tv-update-primary'),
                  autofocus: true,
                  focusNode: _primaryFocus,
                  style: _focusStyle(context),
                  onPressed: _installing
                      ? null
                      : _downloading
                          ? _cancelDownload
                          : _apk != null
                              ? _install
                              : _download,
                  child: Text(buttonText),
                )),
          ],
        ),
      ),
    );
  }

  ButtonStyle _focusStyle(BuildContext context) => ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(136, 52)),
        side: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.focused)
                ? BorderSide(
                    color: Theme.of(context).colorScheme.onSurface, width: 3)
                : BorderSide.none),
      );
}
