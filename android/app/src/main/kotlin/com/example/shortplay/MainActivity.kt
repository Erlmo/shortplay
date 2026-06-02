package com.example.shortplay

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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

    private val channelName = "shortplay/crypto"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.plugins.add(NativePlayerPlugin())

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
