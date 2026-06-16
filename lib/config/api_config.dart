class ApiConfig {
  // Nove API配置
  static const String noveBaseUrl = 'http://api.weeou.com';
  static const String noveSearch = '/nove/search';
  static const String noveHome = '/nove/home';
  static const String noveRank = '/nove/rank';
  static const String noveDirectory = '/nove/directory';
  static const String noveDanmaku = '/nove/danmaku';

  // 番茄视频API配置
  static const String fqVideoHost = 'api3-normal-sinfonlinea.fqnovel.com';
  static const String fqVideoPath = '/novel/player/video_model/v1/';
  static const String algorithmSign = '/algorithm/sign';
  static const String algorithmSpade = '/algorithm/spade';
  static const String fqUserAgent =
      'com.dragon.read/72132 (Linux; U; Android 13; zh_CN; Mi 10; Build/TKQ1.221114.001; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';
  static const String fqAid = '1967';
  static const String fqQueryParams =
      'klink_egdi=AAIY6G6NjvwuLMs5Vtk3IQ2ySE6PNDIMSSU8dA5h54oouVm0RqwHdthu&iid=2679927861680508&device_id=2091692636517337&ac=wifi&channel=update_64&aid=1967&app_name=novelapp&version_code=72132&version_name=7.2.1.32&device_platform=android&os=android&ssmix=a&device_type=Mi+10&device_brand=Xiaomi&language=zh&os_api=33&os_version=13&manifest_version_code=72132&resolution=1080*2206&dpi=440&update_version_code=72132&_rticket=1781605122538&&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=72132&compliance_status=0&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&rom_version=miui_V140_V14.0.3.0.TJBCNXM&cdid=75e2081b-d8bf-4767-91e8-3424546b4d2e';

  // 超时配置
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration sendTimeout = Duration(seconds: 30);

  // 搜索配置
  static const int searchPageSize = 20;
  static const int maxHistoryItems = 50;
}
