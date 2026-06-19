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

  /// 为请求各部分生成签名，失败返回 null。
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
      // body 长度须按 UTF-8 字节数传入，与 native 侧口径一致。Dart 的
      // body.length 是 UTF-16 码元数，纯 ASCII 时恰好相等，但含中文/《》的
      // body（如 /nove/share 的口令文本）会偏小导致校验失败。pBody.length
      // 是 toNativeUtf8 写出的 UTF-8 字节数（不含结尾 \0）。
      final bodyByteLen = pBody.length;
      final len = _sign(pMethod, pPath, pQuery, pBody, bodyByteLen, pOut);
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
