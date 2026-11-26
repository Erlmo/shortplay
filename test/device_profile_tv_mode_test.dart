import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shortplay/services/device_profile.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceProfile.isTv = false;
  });

  test('手动开启和关闭电视模式会切换界面并保存', () async {
    final before = DeviceProfile.revision.value;

    await DeviceProfile.setTvMode(TvModeSetting.on);
    expect(DeviceProfile.isTv, isTrue);
    expect(DeviceProfile.revision.value, before + 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('device_profile.tv_mode'), 'on');

    await DeviceProfile.setTvMode(TvModeSetting.off);
    expect(DeviceProfile.isTv, isFalse);
    expect(DeviceProfile.revision.value, before + 2);
    expect(prefs.getString('device_profile.tv_mode'), 'off');
  });

  testWidgets('自动模式下按遥控器确认键识别为电视，手动关闭仍可切回手机', (tester) async {
    await DeviceProfile.setTvMode(TvModeSetting.auto);
    expect(DeviceProfile.isTv, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(DeviceProfile.isTv, isTrue);
    expect(DeviceProfile.autoDetectedTv, isTrue);

    await DeviceProfile.setTvMode(TvModeSetting.off);
    expect(DeviceProfile.isTv, isFalse);
  });
}
