import 'package:connectivity_plus/connectivity_plus.dart';

/// 网络检测工具类
/// 用于检测网络状态，优化预加载策略
class NetworkHelper {
  NetworkHelper._();

  static final _connectivity = Connectivity();

  /// 检查是否连接到WiFi
  /// 返回true表示WiFi环境，可以更激进地预加载
  static Future<bool> isWiFi() async {
    try {
      final results = await _connectivity.checkConnectivity();
      // connectivity_plus 6.0+返回List<ConnectivityResult>
      return results.contains(ConnectivityResult.wifi);
    } catch (e) {
      // 网络检测失败，降级为保守策略
      return false;
    }
  }

  /// 检查是否有网络连接
  static Future<bool> hasNetwork() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return results.isNotEmpty && !results.contains(ConnectivityResult.none);
    } catch (e) {
      return false;
    }
  }

  /// 获取预加载剧集数量
  /// WiFi环境下预加载更多集，移动网络下保守预加载
  static Future<PreloadConfig> getPreloadConfig() async {
    final isWifi = await isWiFi();
    if (isWifi) {
      return PreloadConfig(
        nextCount: 2, // 预加载后面2集
        previousCount: 1, // 预加载前面1集
        description: 'WiFi环境，激进预加载',
      );
    } else {
      return PreloadConfig(
        nextCount: 1, // 预加载后面1集
        previousCount: 0, // 不预加载前面的
        description: '移动网络，保守预加载',
      );
    }
  }
}

/// 预加载配置
class PreloadConfig {
  /// 预加载后面多少集
  final int nextCount;

  /// 预加载前面多少集
  final int previousCount;

  /// 配置描述
  final String description;

  const PreloadConfig({
    required this.nextCount,
    required this.previousCount,
    required this.description,
  });

  /// 总预加载数量
  int get totalCount => nextCount + previousCount;
}
