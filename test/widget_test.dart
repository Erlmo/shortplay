import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/main.dart';
import 'package:shortplay/pages/global_search_page.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/download_service.dart';

void main() {
  testWidgets('首页搜索入口打开搜索页面', (tester) async {
    final apiClient = ApiClient();
    await tester.pumpWidget(ShortPlayApp(
      apiClient: apiClient,
      downloadService: DownloadService(apiClient: apiClient),
    ));
    expect(find.byIcon(Icons.search), findsOneWidget);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(GlobalSearchPage), findsOneWidget);
  });
}
