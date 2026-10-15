import 'package:shortplay/services/api_client.dart';
import 'package:shortplay/services/app_update_service.dart';

/// 与更新无关的页面测试不访问真实更新服务或平台插件。
class NoAppUpdates extends AppUpdateService {
  NoAppUpdates(ApiClient client) : super(apiClient: client);

  @override
  bool get isSupported => false;
}
