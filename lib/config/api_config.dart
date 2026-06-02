class ApiConfig {
  // Nove API配置
  static const String noveBaseUrl = 'http://api.weeou.com';
  static const String noveSearch = '/nove/search';
  static const String noveHome = '/nove/home';
  static const String noveRank = '/nove/rank';
  static const String noveDirectory = '/nove/directory';
  static const String noveDanmaku = '/nove/danmaku';

  // 番茄视频API配置
  static const String fqVideoHost = 'api5-normal-sinfonlinea.fqnovel.com';
  static const String fqVideoPath = '/novel/player/video_model/v1/';
  static const String algorithmSign = '/algorithm/sign';
  static const String algorithmSpade = '/algorithm/spade';
  static const String fqUserAgent =
      'com.kylin.read/71932 (Linux; U; Android 13; zh_CN; Mi 10; Build/TKQ1.221114.001; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';
  static const String fqAid = '8704';
  static const String fqQueryParams =
      'iid=2820661174421707&device_id=2091692636517337&ac=wifi&channel=01_duanju_cn_rxc_cl_03&aid=8704&app_name=kylin_read&version_code=71932&version_name=7.1.9.32&device_platform=android&os=android&ssmix=a&device_type=Mi+10&device_brand=Xiaomi&language=zh&os_api=33&os_version=13&manifest_version_code=71932&resolution=1080*2206&dpi=440&update_version_code=71932&_rticket=1779919108715&&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=71932&compliance_status=0&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&rom_version=miui_V140_V14.0.3.0.TJBCNXM&cdid=407f8182-ee80-48a0-84f6-19cfbe1d77e1';

  // 超时配置
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration sendTimeout = Duration(seconds: 30);

  // 搜索配置
  static const int searchPageSize = 20;
  static const int maxHistoryItems = 50;
}
