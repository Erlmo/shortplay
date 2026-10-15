package com.example.shortplay

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

/**
 * Hosts the "shortplay/crypto" MethodChannel that lets the Dart layer register
 * the native "crypto://" libmpv protocol against a media_kit Player handle.
 *
 * The Dart side passes the mpv handle (from `await player.handle`) once per
 * Player instance, before `player.open(...)`. Registration resolves
 * mpv_stream_cb_add_ro at runtime from the libmpv that media_kit already
 * loaded, so no extra native linkage is required here.
 */
class MainActivity : FlutterActivity() {

    private fun isTelevision(): Boolean {
        val uiMode = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        // 部分国产电视盒子不报 TELEVISION 模式，但声明了 leanback 特性
        return packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private val channelName = "shortplay/crypto"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.plugins.add(NativePlayerPlugin())
        AppUpdateBridge(this).register(flutterEngine.dartExecutor.binaryMessenger)

        // 播放页底部导航栏/手势条自动隐藏（红果同款）：上滑临时显示，随后自动收起
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.shortplay/ui",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setNavigationBarAutoHidden" -> {
                    val hidden = call.argument<Boolean>("hidden") ?: false
                    val controller =
                        WindowCompat.getInsetsController(window, window.decorView)
                    if (hidden) {
                        controller.systemBarsBehavior =
                            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                        controller.hide(WindowInsetsCompat.Type.navigationBars())
                    } else {
                        controller.show(WindowInsetsCompat.Type.navigationBars())
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // 设备形态：Dart 侧据此切换遥控器操作、不锁竖屏
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "shortplay/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> result.success(isTelevision())
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "registerCryptoProtocol" -> {
                    val handle = when (val raw = call.argument<Any?>("handle")) {
                        is Number -> raw.toLong()
                        is String -> raw.toLongOrNull() ?: 0L
                        else -> 0L
                    }
                    if (handle == 0L) {
                        result.error("BAD_HANDLE", "missing or zero mpv handle", null)
                        return@setMethodCallHandler
                    }
                    // CryptoNative may dlopen libmpv on first use; keep it off
                    // the platform thread.
                    Thread {
                        val status = try {
                            CryptoNative.registerCryptoProtocol(handle)
                        } catch (t: Throwable) {
                            -1
                        }
                        runOnUiThread { result.success(status) }
                    }.start()
                }

                "prewarm" -> {
                    val url = call.argument<String>("url")
                    val key = call.argument<String>("key")
                    if (url.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "missing url", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val status = try {
                            CryptoNative.prewarm(url, key ?: "")
                        } catch (t: Throwable) {
                            -1
                        }
                        runOnUiThread { result.success(status) }
                    }.start()
                }

                "prewarmHeaderOnly" -> {
                    val url = call.argument<String>("url")
                    val key = call.argument<String>("key")
                    if (url.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "missing url", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val status = try {
                            CryptoNative.prewarmHeaderOnly(url, key ?: "")
                        } catch (t: Throwable) {
                            -1
                        }
                        runOnUiThread { result.success(status) }
                    }.start()
                }

                "prewarmSeedMdat" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "missing url", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val status = try {
                            CryptoNative.prewarmSeedMdat(url)
                        } catch (t: Throwable) {
                            -1
                        }
                        runOnUiThread { result.success(status) }
                    }.start()
                }

                "decryptToFile" -> {
                    val url = call.argument<String>("url")
                    val key = call.argument<String>("key")
                    val outputPath = call.argument<String>("outputPath")
                    if (url.isNullOrEmpty() || key.isNullOrEmpty() || outputPath.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "missing url/key/outputPath", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val status = try {
                            CryptoNative.decryptToFile(url, key, outputPath)
                        } catch (t: Throwable) {
                            -1
                        }
                        runOnUiThread { result.success(status) }
                    }.start()
                }

                else -> result.notImplemented()
            }
        }
    }
}
