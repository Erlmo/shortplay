import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _WeeouSignC = Int32 Function(
  Pointer<Utf8> method,
  Pointer<Utf8> path,
  Pointer<Utf8> query,
  Pointer<Utf8> body,
  Int32 bodyLen,
  Pointer<Utf8> outBuf,
);
typedef _WeeouSignDart = int Function(
  Pointer<Utf8> method,
  Pointer<Utf8> path,
  Pointer<Utf8> query,
  Pointer<Utf8> body,
  int bodyLen,
  Pointer<Utf8> outBuf,
);

class SignNative {
  SignNative._();
  static final SignNative instance = SignNative._();

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  late final _WeeouSignDart _sign = _load();

  _WeeouSignDart _load() {
    final DynamicLibrary lib;
    if (Platform.isIOS) {
      lib = DynamicLibrary.process();
    } else {
      lib = DynamicLibrary.open('libweeou_sign.so');
    }
    return lib.lookupFunction<_WeeouSignC, _WeeouSignDart>('weeou_sign');
  }

  /// Generate X-Dusa signature for the given request parts.
  /// Returns the base64 signature string, or null on failure.
  String? sign({
    required String method,
    required String path,
    required String query,
    required String body,
  }) {
    final pMethod = method.toNativeUtf8();
    final pPath = path.toNativeUtf8();
    final pQuery = query.toNativeUtf8();
    final pBody = body.toNativeUtf8();
    final pOut = calloc<Uint8>(64).cast<Utf8>();

    try {
      final len = _sign(pMethod, pPath, pQuery, pBody, body.length, pOut);
      if (len <= 0) return null;
      return pOut.toDartString();
    } finally {
      calloc.free(pMethod);
      calloc.free(pPath);
      calloc.free(pQuery);
      calloc.free(pBody);
      calloc.free(pOut);
    }
  }
}
