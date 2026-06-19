class ApiConfig {
  // Nove API配置
  static const String noveBaseUrl = 'http://api.weeou.com';
  static const String noveSearch = '/nove/search';
  static const String noveHome = '/nove/home';
  static const String noveRank = '/nove/rank';
  static const String noveDirectory = '/nove/directory';
  static const String noveDanmaku = '/nove/danmaku';
  static const String notice = '/notice';
  static const String noveShare = '/nove/share';

  // 番茄视频API配置
  static const String fqVideoHost = 'api3-normal-sinfonlinea.fqnovel.com';
  static const String fqVideoPath = '/novel/player/video_model/v1/';
  static const String algorithmSign = '/algorithm/sign';
  static const String algorithmSpade = '/algorithm/spade';
  static const String fqUserAgent =
      'com.dragon.read/72132 (Linux; U; Android 13; zh_CN; Mi 10; Build/TKQ1.221114.001; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';
  static const String fqAid = '1967';

  // 超时配置
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration sendTimeout = Duration(seconds: 30);

  // 搜索配置
  static const int searchPageSize = 20;
  static const int maxHistoryItems = 50;
}
