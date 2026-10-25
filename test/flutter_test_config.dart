import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/registered_device.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(seedRegisteredDevice);
  await testMain();
}
