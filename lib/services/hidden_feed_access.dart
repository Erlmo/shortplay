import 'package:shared_preferences/shared_preferences.dart';

/// 只保存本机首页模式；切换必须先在识别页通过服务端口令验证。
class HiddenFeedAccess {
  static const preferenceKey = 'twixive_feed_enabled';
  bool enabled = false;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    enabled = preferences.getBool(preferenceKey) ?? false;
  }

  Future<void> toggle() async {
    final preferences = await SharedPreferences.getInstance();
    final next = !(preferences.getBool(preferenceKey) ?? false);
    if (!await preferences.setBool(preferenceKey, next)) {
      throw StateError('首页模式保存失败');
    }
    enabled = next;
  }
}
