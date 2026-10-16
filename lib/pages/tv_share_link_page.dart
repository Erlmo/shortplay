import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/drama.dart';
import '../services/api_client.dart';
import '../services/download_service.dart';
import '../services/share_link_resolver.dart';
import '../services/tv_link_api.dart';
import 'player_page.dart';

class TvShareLinkPage extends StatefulWidget {
  const TvShareLinkPage(
      {super.key,
      required this.apiClient,
      this.downloadService,
      this.tvLinkApi});

  final ApiClient apiClient;
  final DownloadService? downloadService;
  final TvLinkApi? tvLinkApi;

  @override
  State<TvShareLinkPage> createState() => _TvShareLinkPageState();
}

class _TvShareLinkPageState extends State<TvShareLinkPage>
    with WidgetsBindingObserver {
  late final TvLinkApi _api = widget.tvLinkApi ?? TvLinkApi(widget.apiClient);
  TvLinkSession? _session;
  Timer? _timer;
  CancelToken _cancelToken = CancelToken();
  int _generation = 0;
  bool _creating = false;
  bool _polling = false;
  bool _resolving = false;
  bool _foreground = true;
  bool _closing = false;
  String? _receivedText;
  String? _error;

  bool get _canAct =>
      mounted &&
      !_closing &&
      _foreground &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _cancelToken.cancel('扫码页面已关闭');
    final session = _session;
    if (session != null) unawaited(_discard(session));
    super.dispose();
  }

  Future<void> _discard(TvLinkSession session) async {
    try {
      await _api.cancel(session);
    } catch (_) {/* 关闭后的会话也会自动过期。 */}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _timer?.cancel();
    } else if (!_creating && !_resolving && _receivedText == null) {
      _schedulePoll(Duration.zero);
    }
  }

  Future<void> _refresh() async {
    if (_creating || _resolving) return;
    final generation = ++_generation;
    _timer?.cancel();
    _cancelToken.cancel('刷新二维码');
    _cancelToken = CancelToken();
    final previous = _session;
    if (previous != null) unawaited(_discard(previous));
    setState(() {
      _session = null;
      _error = null;
      _receivedText = null;
      _creating = true;
      _polling = false;
    });
    try {
      final session = await _api.create(cancelToken: _cancelToken);
      if (!mounted || generation != _generation) return;
      if (session.expiresAt.isBefore(DateTime.now())) {
        throw ApiException('二维码已过期，请刷新');
      }
      setState(() => _session = session);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() =>
            _error = error is ApiException ? error.message : '二维码加载失败，请重试');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _creating = false);
        _schedulePoll(Duration.zero);
      }
    }
  }

  void _schedulePoll([Duration delay = const Duration(seconds: 3)]) {
    _timer?.cancel();
    if (!mounted ||
        _closing ||
        !_foreground ||
        _session == null ||
        _receivedText != null ||
        _resolving) {
      return;
    }
    _timer = Timer(delay, () => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (!_canAct || _polling || _resolving) {
      _schedulePoll();
      return;
    }
    final session = _session;
    if (session == null) return;
    if (!session.expiresAt.isAfter(DateTime.now())) {
      setState(() {
        _session = null;
        _error = '二维码已过期，请刷新后重新扫码';
      });
      return;
    }
    final generation = _generation;
    _polling = true;
    try {
      final status = await _api.status(session, cancelToken: _cancelToken);
      if (!_canAct || generation != _generation) return;
      if (status.state == 'submitted') {
        _receivedText = status.text!;
        await _resolve();
      } else if (status.state == 'consumed') {
        setState(() {
          _session = null;
          _error = '二维码已使用，请刷新后重新扫码';
        });
      } else if (_error != null) {
        setState(() => _error = null);
      }
    } catch (error) {
      if (_canAct && generation == _generation) {
        setState(() {
          _error = error is ApiException ? error.message : '连接中断，正在重试…';
          if (error is ApiException && error.code == 410) _session = null;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        _polling = false;
        _schedulePoll();
      }
    }
  }

  Future<void> _resolve() async {
    final text = _receivedText;
    final session = _session;
    if (!_canAct || _resolving || text == null || session == null) return;
    final generation = _generation;
    _timer?.cancel();
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      final info = await widget.apiClient.fetchShareInfo(text);
      if (!_canAct || generation != _generation) return;
      final id = int.tryParse(info.videoId);
      if (id == null || id <= 0) throw ApiException('未识别到有效短剧，请重新扫码发送');
      Drama? detail;
      try {
        detail = await widget.apiClient
            .fetchBookInfo(info.videoId)
            .timeout(const Duration(seconds: 6));
      } catch (_) {/* 详情失败时保留分享标题，播放页会重新加载目录。 */}
      if (!_canAct || generation != _generation) return;
      final drama = detail != null && detail.id == id
          ? detail
          : Drama(
              id: id,
              name:
                  info.title ?? ShareLinkResolver.extractTitle(text) ?? '分享短剧',
              actors: '',
              cover: '',
              intro: '',
              tags: const [],
              status: '',
              updateTime: '',
              isTheaterResource: true);
      await _api.acknowledge(session, cancelToken: _cancelToken);
      if (!mounted || !_canAct || generation != _generation) return;
      _closing = true;
      await Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(
        builder: (_) => PlayerPage(
            drama: drama,
            apiClient: widget.apiClient,
            downloadService: widget.downloadService,
            initialEpisodeIndex: 0),
      ));
    } catch (error) {
      if (_canAct && generation == _generation) {
        setState(() =>
            _error = error is ApiException ? error.message : '识别失败，请重试或重新扫码发送');
      }
    } finally {
      if (mounted && !_closing && generation == _generation) {
        setState(() => _resolving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _closing = true;
          _timer?.cancel();
          _cancelToken.cancel();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F5F8),
        appBar: AppBar(
            title: const Text('手机扫码播放'),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent),
        body: SafeArea(
            top: false,
            child: Center(
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Row(children: [
                  Container(
                      width: 280,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22)),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                            width: 240,
                            height: 240,
                            child: _creating
                                ? const Center(
                                    child: CircularProgressIndicator())
                                : _session == null
                                    ? const Icon(Icons.qr_code_rounded,
                                        size: 96, color: Color(0xFFB3BAC7))
                                    : QrImageView(
                                        data: _session!.inputUrl,
                                        size: 240,
                                        backgroundColor: Colors.white,
                                        semanticsLabel: '手机扫码输入分享链接')),
                        const SizedBox(height: 12),
                        const Text('使用手机相机或微信扫码',
                            style: TextStyle(
                                fontSize: 14, color: Color(0xFF747B88))),
                        const SizedBox(height: 5),
                        const Text('二维码5分钟内有效',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF969CAB))),
                      ])),
                  const SizedBox(width: 40),
                  Expanded(
                      child: SingleChildScrollView(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                        const Text('手机粘贴链接\n电视自动播放',
                            style: TextStyle(
                                fontSize: 27,
                                height: 1.4,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF242833))),
                        const SizedBox(height: 18),
                        const Text(
                            '1  手机扫码打开输入页面\n2  粘贴分享链接或整段口令\n3  点击发送，电视识别后播放',
                            style: TextStyle(
                                fontSize: 14,
                                height: 2,
                                color: Color(0xFF747B88))),
                        const SizedBox(height: 18),
                        Text(
                            _creating
                                ? '正在生成二维码…'
                                : _resolving
                                    ? '已收到分享，正在识别…'
                                    : _receivedText != null
                                        ? '已收到分享内容'
                                        : '等待手机发送…',
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFFFF5866))),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(_error!,
                              style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  color: Color(0xFFC44E60))),
                        ],
                        const SizedBox(height: 20),
                        Wrap(spacing: 12, runSpacing: 10, children: [
                          FilledButton(
                              onPressed:
                                  _creating || _resolving ? null : _refresh,
                              autofocus: true,
                              child: const Text('刷新二维码')),
                          if (_receivedText != null && !_resolving)
                            OutlinedButton(
                                onPressed: _resolve, child: const Text('重试识别')),
                        ]),
                      ]))),
                ]),
              ),
            ))),
      ),
    );
  }
}
