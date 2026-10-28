import 'package:flutter/material.dart';

import '../models/app_update.dart';
import '../services/app_update_service.dart';
import 'android_app_update_dialog.dart';

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.update,
    required this.service,
  });

  final AppUpdate update;
  final AppUpdateService service;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _opening = false;
  String? _error;
  bool _opened = false;

  Future<void> _openUpdate() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await widget.service.openUpdate(widget.update);
      if (mounted) setState(() => _opened = true);
    } catch (error) {
      if (mounted) setState(() => _error = appUpdateError(error));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.service.usesInAppUpdate) {
      return AndroidAppUpdateDialog(
          update: widget.update, service: widget.service);
    }
    return PopScope(
      canPop: !widget.update.isRequired,
      child: AlertDialog(
        title: Text(widget.update.isRequired
            ? '需要更新至 ${widget.update.version}'
            : '发现新版本 ${widget.update.version}'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.update.isRequired) ...[
                const Text('请完成更新后继续使用'),
                const SizedBox(height: 12),
              ],
              Text(widget.update.releaseNotes.trim().isEmpty
                  ? '修复问题并改善使用体验'
                  : widget.update.releaseNotes),
              if (_opened) ...[
                const SizedBox(height: 16),
                const Text('已打开更新链接，请按页面提示完成更新'),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
        actions: [
          if (!widget.update.isRequired)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('稍后'),
            ),
          FilledButton(
            autofocus: true,
            onPressed: _opening ? null : _openUpdate,
            child: Text(_opening ? '正在打开…' : '立即更新'),
          ),
        ],
      ),
    );
  }
}
