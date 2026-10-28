package com.example.shortplay

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.ClipData
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
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
                "updateDirectory" -> {
                    val directory = File(activity.cacheDir, "updates")
                    if (directory.isDirectory || directory.mkdirs()) result.success(directory.absolutePath)
                    else result.error("DOWNLOAD_DIRECTORY", "无法创建更新下载目录", null)
                }
                "canInstallApks" -> result.success(canInstallApks())
                "installApk" -> installApk(call.argument<String>("path"), result)
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

    private fun canInstallApks(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    private fun installApk(path: String?, result: MethodChannel.Result) {
        // APK解析和证书校验放在后台，避免主线程卡顿。
        Thread {
            try {
                val directory = File(activity.cacheDir, "updates").canonicalFile
                val file = path?.let { File(it).canonicalFile }
                if (file == null || file.parentFile != directory || !file.name.endsWith(".apk") ||
                    !file.isFile || file.length() == 0L) {
                    throw UpdateException("INVALID_APK", "安装包不可用，请重新下载")
                }
                validateApk(file)
                activity.runOnUiThread {
                    if (activity.isFinishing || activity.isDestroyed) {
                        result.error("ACTIVITY_CLOSED", "更新窗口已关闭，请重试", null)
                    } else {
                        openInstaller(file, result)
                    }
                }
            } catch (error: UpdateException) {
                activity.runOnUiThread { result.error(error.code, error.message, null) }
            } catch (_: Exception) {
                activity.runOnUiThread { result.error("INVALID_APK", "安装包校验失败，请确认下载地址为 APK 文件", null) }
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun validateApk(file: File) {
        val pm = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val apk = pm.getPackageArchiveInfo(file.absolutePath, flags)
            ?: throw UpdateException("INVALID_APK", "下载内容不是有效 APK，请检查更新下载链接")
        if (apk.packageName != activity.packageName) {
            throw UpdateException("WRONG_APP", "安装包不属于龙龙短剧，请检查更新下载链接")
        }
        val installed = pm.getPackageInfo(activity.packageName, flags)
        val validSignature = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signers = apk.signingInfo?.apkContentsSigners
            !signers.isNullOrEmpty() && signers.all {
                pm.hasSigningCertificate(activity.packageName,
                    MessageDigest.getInstance("SHA-256").digest(it.toByteArray()),
                    PackageManager.CERT_INPUT_SHA256)
            }
        } else {
            val signers = apk.signatures?.map { it.toCharsString() }?.toSet()
            !signers.isNullOrEmpty() && signers == installed.signatures?.map { it.toCharsString() }?.toSet()
        }
        if (!validSignature) throw UpdateException("WRONG_SIGNATURE", "安装包签名不一致，无法覆盖更新")
        val apkVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) apk.longVersionCode else apk.versionCode.toLong()
        val currentVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) installed.longVersionCode else installed.versionCode.toLong()
        if (apkVersion <= currentVersion) {
            throw UpdateException("NOT_NEWER", "下载的安装包不是更新版本，请检查服务端更新配置")
        }
    }

    private fun openInstaller(file: File, result: MethodChannel.Result) {
        try {
            if (!canInstallApks()) {
                try {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}")))
                } catch (_: ActivityNotFoundException) {
                    activity.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                }
                result.success("permission_required")
                return
            }
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri("APK", uri)
            }
            activity.startActivity(intent)
            result.success("installer_opened")
        } catch (_: ActivityNotFoundException) {
            result.error("NO_INSTALLER", "无法打开安装或授权界面，请检查设备的应用安装设置", null)
        } catch (_: Exception) {
            result.error("INSTALL_FAILED", "无法启动系统安装，请检查安装权限后重试", null)
        }
    }

    private class UpdateException(val code: String, message: String) : Exception(message)

}

// 独立Provider只共享更新目录，不暴露应用的其他缓存。
class AppUpdateFileProvider : FileProvider()
