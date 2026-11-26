import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/screen_awake_controller.dart';

void main() {
  late List<bool> calls;
  late ScreenAwakeController controller;

  setUp(() {
    calls = [];
    controller = ScreenAwakeController(
      setKeepScreenOn: (on) async => calls.add(on),
      idleGrace: const Duration(seconds: 30),
    );
  });

  testWidgets('播放结束后过了宽限期恢复自动熄屏', (tester) async {
    controller.hold();
    controller.setPlaying(true);
    expect(calls, [true]);

    // 全剧播完：播放器停在最后一集
    controller.setPlaying(false);
    await tester.pump(const Duration(seconds: 29));
    expect(calls, [true]);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, [true, false]);
    controller.dispose();
  });

  testWidgets('切集时短暂停顿不会关闭常亮', (tester) async {
    controller.hold();
    controller.setPlaying(true);
    controller.setPlaying(false);
    await tester.pump(const Duration(seconds: 3));
    controller.hold();
    controller.setPlaying(true);
    await tester.pump(const Duration(minutes: 5));
    expect(calls, [true]);
    controller.dispose();
    expect(calls, [true, false]);
  });

  testWidgets('一直没播起来也会在宽限期后放开', (tester) async {
    controller.hold();
    await tester.pump(const Duration(seconds: 31));
    expect(calls, [true, false]);
    controller.dispose();
    expect(calls, [true, false]);
  });

  testWidgets('定时停止立即放开，之后播放状态变化不再重新常亮', (tester) async {
    controller.hold();
    controller.setPlaying(true);
    controller.release();
    controller.setPlaying(false);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, [true, false]);
    controller.dispose();
  });
}
