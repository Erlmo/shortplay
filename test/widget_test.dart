import 'package:flutter_test/flutter_test.dart';

import 'package:shortplay/main.dart';
import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/download_service.dart';

void main() {
  testWidgets('首页展示搜索提示', (tester) async {
    final apiClient = ApiClient();
    await tester.pumpWidget(ShortPlayApp(
      apiClient: apiClient,
      downloadService: DownloadService(apiClient: apiClient),
    ));
    expect(find.text('LongLong'), findsOneWidget);
    expect(find.textContaining('搜索短剧名称'), findsOneWidget);
  });
}
