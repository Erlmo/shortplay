import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drama.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/share_link_resolver.dart';
import 'player_page.dart';

class ShareLinkPage extends StatefulWidget {
  const ShareLinkPage({
    super.key,
    required this.apiClient,
    this.downloadService,
  });

  final ApiClient apiClient;
  final DownloadService? downloadService;

  @override
  State<ShareLinkPage> createState() => _ShareLinkPageState();
}

class _ShareLinkPageState extends State<ShareLinkPage> {
  final _controller = TextEditingController();
  bool _resolving = false;
  bool _pasting = false;
  String? _error;

  bool get _busy => _resolving || _pasting;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    if (_busy) return;
    setState(() => _pasting = true);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text ?? '';
      if (text.trim().isEmpty) {
        setState(() => _error = '剪贴板暂无文字，请先复制分享内容');
        return;
      }
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法读取剪贴板，请长按输入框粘贴');
      }
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Future<void> _resolve() async {
    if (_busy) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请先输入分享链接或口令');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      // 传入整段分享内容，由现有接口处理短链接、口令及平台差异。
      final info = await widget.apiClient.fetchShareInfo(text);
      // 返回动画结束前 State 仍 mounted，此时也不能再打开结果页。
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      final id = int.tryParse(info.videoId);
      if (id == null || id <= 0) {
        throw ApiException('未识别到有效短剧，请检查分享内容后重试');
      }
      final title = info.title?.trim();
      final drama = Drama(
        id: id,
        name: title != null && title.isNotEmpty
            ? title
            : ShareLinkResolver.extractTitle(text) ?? '分享短剧',
        actors: '',
        cover: '',
        intro: '',
        tags: const [],
        status: '',
        updateTime: '',
        isTheaterResource: true,
      );
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => PlayerPage(
          drama: drama,
          apiClient: widget.apiClient,
          downloadService: widget.downloadService,
          initialEpisodeIndex: 0,
        ),
      ));
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '识别失败，请检查网络后重试');
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('分享链接识别',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        centerTitle: false,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            const Text('粘贴分享内容',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            const Text(
              '支持红果短剧、红果漫剧、番茄小说。\n粘贴分享链接或口令，识别后播放第一集。',
              style: TextStyle(
                  fontSize: 14, color: Color(0xFF999999), height: 1.7),
            ),
            const SizedBox(height: 24),
            _buildInput(),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(_error!,
                    style: TextStyle(
                        fontSize: 13, height: 1.5, color: colors.error)),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _resolve,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              child: _resolving
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Text('识别中…'),
                      ],
                    )
                  : const Text('开始识别'),
            ),
            const SizedBox(height: 14),
            const Text('可直接粘贴整段分享文案，无需单独提取链接',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, height: 1.5, color: Color(0xFF999999))),
          ],
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 16),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('分享内容',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () {
                        _controller.clear();
                        setState(() => _error = null);
                      },
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF999999)),
                child: const Text('清空'),
              ),
              TextButton(
                onPressed: _busy ? null : _paste,
                child: const Text('粘贴'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              controller: _controller,
              readOnly: _busy,
              minLines: 6,
              maxLines: 10,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              style: const TextStyle(fontSize: 14, height: 1.6),
              decoration: const InputDecoration(
                hintText: '在这里输入或粘贴分享链接、口令…',
                hintStyle: TextStyle(color: Color(0xFFBBBBBB)),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
