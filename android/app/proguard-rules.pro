# JNI 桥接类：由 native 库 libshortplay_crypto.so 通过反射调用。
#
# CryptoNative.nativeInit 把 HttpBridge::class.java 传给 C 层，C 层再用
# GetStaticMethodID(cls, "httpRange", ...) 等按名字解析这些方法。R8 看不到
# 这些调用点（方法名只以字符串形式存在于 native 代码里），release 构建会把
# 它们当死代码移除/改名，导致 GetStaticMethodID 返回 NULL、nativeInit 抛
# NoSuchMethodError，crypto:// 协议注册失败、播放初始化超时。
#
# 显式保留类名与全部成员，确保 native 侧能按原始名字解析。
-keep class com.example.shortplay.CryptoNative { *; }
-keep class com.example.shortplay.HttpBridge { *; }
