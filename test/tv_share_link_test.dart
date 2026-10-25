import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/pages/player_page.dart';
import 'package:shortplay/pages/settings_page.dart';
import 'package:shortplay/pages/share_link_page.dart';
import 'package:shortplay/pages/tv_share_link_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/device_profile.dart';
import 'package:shortplay/services/tv_link_api.dart';

import 'support/registered_device.dart';

import 'support/no_app_updates.dart';

TvLinkSession session([String character = 'a']) => TvLinkSession(
    id: character * 32,
    readToken: 'b' * 64,
    inputUrl:
        'https://api.weeou.com/tvlink/page#session_id=${character * 32}&token=${'c' * 64}',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)));

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final ResponseBody Function(RequestOptions) reply;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      reply(options);
  @override
  void close({bool force = false}) {}
}

class _Shares extends ApiClient {
  final texts = <String>[];
  Completer<({String videoId, String? title})>? resolution;
  @override
  Future<({String videoId, String? title})> fetchShareInfo(String text) {
    texts.add(text);
    return (resolution ??= Completer<({String videoId, String? title})>())
        .future;
  }

  @override
  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) async =>
      TheaterEpisodesResult(allItemIds: [], chapters: []);
  @override
  Future<List<FqVideoItem>> fetchFqVideoModel(String videoId) async => [];
}

class _Relay extends TvLinkApi {
  _Relay(super.apiClient);
  int creates = 0, reads = 0, acknowledgements = 0;
  final cancelled = <String>[];
  Object? createError;
  TvLinkStatus result = const TvLinkStatus(state: 'pending');
  Completer<TvLinkStatus>? pending;
  @override
  Future<TvLinkSession> create({CancelToken? cancelToken}) async {
    creates++;
    if (createError != null) throw createError!;
    return session(creates == 1 ? 'a' : 'd');
  }

  @override
  Future<TvLinkStatus> status(TvLinkSession session,
      {CancelToken? cancelToken}) {
    reads++;
    return pending?.future ?? Future.value(result);
  }

  @override
  Future<void> acknowledge(TvLinkSession session,
      {CancelToken? cancelToken}) async {
    acknowledgements++;
  }

  @override
  Future<void> cancel(TvLinkSession session) async {
    cancelled.add(session.id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Shares shares;
  late _Relay relay;
  setUp(() {
    seedRegisteredDevice();
    DeviceProfile.isTv = true;
    shares = _Shares();
    relay = _Relay(shares);
    for (final channel in [
      SystemChannels.platform,
      const MethodChannel('shortplay/native_player')
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
    }
  });
  tearDown(() {
    DeviceProfile.isTv = false;
    shares.dio.close(force: true);
    for (final channel in [
      SystemChannels.platform,
      const MethodChannel('shortplay/native_player')
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: TvShareLinkPage(apiClient: shares, tvLinkApi: relay)));
    await tester.pumpAndSettle();
    await tester.pump();
  }

  test('扫码API使用POST凭证且二维码不含电视读取密钥', () async {
    final data = session();
    shares.dio.httpClientAdapter = _Adapter((request) {
      expect(request.uri.path, '/tvlink/create');
      expect(request.method, 'POST');
      expect(
          request.queryParameters, {'client_device': testRegisteredDeviceJson});
      return ResponseBody.fromString(
          jsonEncode({
            'code': 0,
            'data': {
              'session_id': data.id,
              'read_token': data.readToken,
              'input_url': data.inputUrl,
              'expires_at': data.expiresAt.millisecondsSinceEpoch ~/ 1000
            }
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
    });
    final result = await TvLinkApi(shares).create();
    expect(result.inputUrl, isNot(contains(result.readToken)));
    expect(
        () => TvLinkSession.fromJson({
              'session_id': data.id,
              'read_token': data.readToken,
              'input_url': 'https://evil.example/page',
              'expires_at': 9999999999
            }),
        throwsA(isA<ApiException>()));
  });

  testWidgets('电视显示可扫描二维码，无输入框，刷新撤销旧会话', (tester) async {
    await open(tester);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel,
        '手机扫码输入分享链接');
    expect(find.byType(TextField), findsNothing);
    expect(find.text('等待手机发送…'), findsOneWidget);
    await tester.tap(find.text('刷新二维码'));
    await tester.pumpAndSettle();
    expect(relay.creates, 2);
    expect(relay.cancelled, contains('a' * 32));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('手机投递后电视确认一次并直接播放，关闭扫码页不重复播放', (tester) async {
    await open(tester);
    relay.result = const TvLinkStatus(
        state: 'submitted', text: '《测试》https://novelquickapp.com/s/example');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(shares.texts.length, 1);
    shares.resolution!
        .complete((videoId: '7621200213801176126', title: '扫码剧名'));
    await tester.pumpAndSettle();
    expect(relay.acknowledgements, 1);
    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.drama.id, 7621200213801176126);
    expect(player.initialEpisodeIndex, 0);
    expect(find.byType(TvShareLinkPage), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(shares.texts.length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('离开扫码页后迟到的投递不会打开播放器', (tester) async {
    relay.pending = Completer<TvLinkStatus>();
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => TvShareLinkPage(
                                apiClient: shares, tvLinkApi: relay))),
                    child: const Text('打开扫码'))))));
    await tester.tap(find.text('打开扫码'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(TvShareLinkPage))).pop();
    await tester.pump();
    relay.pending!
        .complete(const TvLinkStatus(state: 'submitted', text: '迟到的链接'));
    await tester.pumpAndSettle();
    expect(shares.texts, isEmpty);
    expect(find.byType(PlayerPage), findsNothing);
    expect(relay.cancelled, contains('a' * 32));
  });

  testWidgets('创建失败可重试，电视设置只显示扫码入口', (tester) async {
    relay.createError = ApiException('请先上传扫码服务端文件');
    await open(tester);
    expect(find.text('请先上传扫码服务端文件'), findsOneWidget);
    relay.createError = null;
    await tester.tap(find.text('刷新二维码'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.pumpWidget(MaterialApp(
        home: SettingsPage(
            apiClient: shares, appUpdateService: NoAppUpdates(shares))));
    await tester.pumpAndSettle();
    expect(find.text('手机扫码播放'), findsOneWidget);
    expect(find.text('分享链接识别'), findsNothing);
    DeviceProfile.isTv = false;
    await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        home: SettingsPage(
            apiClient: shares, appUpdateService: NoAppUpdates(shares))));
    await tester.pumpAndSettle();
    expect(find.text('分享链接识别'), findsOneWidget);
    expect(find.byType(ShareLinkPage), findsNothing);
  });
}
