class ApiConfig {
  // Nove API配置
  static const String noveBaseUrl = String.fromEnvironment(
    'SHORTPLAY_API_BASE_URL',
    defaultValue: 'http://api.weeou.com',
  );
  static const String noveSearch = '/nove/search';
  static const String noveSearchSuggest = '/nove/search/suggest';
  static const String noveSearchSeason = '/nove/search/season';
  static const String noveHome = '/nove/home';
  static const String noveRank = '/nove/rank';
  static const String noveDirectory = '/nove/directory';
  static const String noveSeasons = '/nove/seasons';
  static const String noveDanmaku = '/nove/danmaku';
  static const String notice = '/notice';
  static const String noveShare = '/nove/share';
  static const String appUpdate = '/update/check';

  // 服务端下发请求规则，客户端执行上游请求并回传响应。
  static const String algorithmVideo = '/algorithm/video'; // 旧包兼容接口。
  static const String algorithmVideoRequest = '/algorithm/videorequest';
  static const String algorithmVideoResult = '/algorithm/videoresult';
  static const Duration videoResolutionTimeout = Duration(seconds: 30);
  static const String algorithmSpade = '/algorithm/spade';

  // 超时配置
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration sendTimeout = Duration(seconds: 30);

  // 搜索配置
  static const int searchPageSize = 20;
  static const int maxHistoryItems = 50;
}
