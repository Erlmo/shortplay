package com.example.shortplay

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class AppUpdateBridge(private val activity: Activity) {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "shortplay/update").setMethodCallHandler { call, result ->
            when (call.method) {
                // 按系统支持的架构选择；64 位设备即使当前装了 32 位应用也可更新到 64 位。
                "device" -> result.success(
                    if (Build.SUPPORTED_64_BIT_ABIS.contains("arm64-v8a")) "android64"
                    else "android32",
                )
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    val uri = url?.let { Uri.parse(it) }
                    if (uri == null || uri.scheme !in listOf("http", "https") || uri.host.isNullOrEmpty()) {
                        result.error("INVALID_URL", "更新链接无效", null)
                        return@setMethodCallHandler
                    }
                    try {
                        activity.startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(true)
                    } catch (_: ActivityNotFoundException) {
                        result.error("NO_BROWSER", "设备上没有可打开更新链接的浏览器", null)
                    } catch (_: Exception) {
                        result.error("OPEN_FAILED", "无法打开更新链接，请稍后重试", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
