package com.example.shortplay

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.WindowManager
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class NativePlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    io.flutter.embedding.engine.plugins.activity.ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var flutterBinding: FlutterPlugin.FlutterPluginBinding

    private var activity: Activity? = null
    private val players = ConcurrentHashMap<Int, PlayerInstance>()
    private val nextId = AtomicInteger(1)
    private val handler = Handler(Looper.getMainLooper())
    private val backgroundExecutor = Executors.newCachedThreadPool()

    private var eventSink: EventChannel.EventSink? = null

    private data class PlayerInstance(
        val id: Int,
        val player: ExoPlayer,
        val textureEntry: TextureRegistry.SurfaceTextureEntry,
        val streams: StreamSlot?,
        val surface: Surface
    )

    /**
     * Owns every native crypto stream of one player.
     *
     * - The handle pre-opened in handleCreate (validation + layout build) is
     *   handed to the first CryptoDataSource.open() instead of being left idle.
     *   Previously it was never read, yet its producer thread streamed up to
     *   16MB in parallel with the DataSource's own stream (double download).
     * - setActive() parks/unparks every live handle so a paused prev/next
     *   player stops competing for bandwidth with the on-screen episode.
     * - release() aborts live handles so a reader blocked on a parked stream
     *   returns and ExoPlayer can close its DataSource.
     */
    private class StreamSlot(pending: Long) {
        private val lock = Any()
        private var pending: Long = pending
        private val live = HashSet<Long>()
        private var active = true
        private var released = false

        /** Returns a handle for a DataSource; opens a new one if none pending. */
        fun acquire(cdnUrl: String, keyHex: String): Long {
            var h: Long
            synchronized(lock) {
                if (released) throw java.io.IOException("player released")
                h = pending
                pending = 0L
            }
            if (h == 0L) {
                // Network work: never under the lock (setActive runs on main).
                h = CryptoNative.nativePlayerStreamOpen(cdnUrl, keyHex)
                if (h == 0L) throw java.io.IOException("Failed to open crypto stream")
            }
            synchronized(lock) {
                if (released) {
                    CryptoNative.nativePlayerStreamClose(h)
                    throw java.io.IOException("player released")
                }
                live.add(h)
                if (!active) CryptoNative.nativePlayerStreamSetActive(h, false)
            }
            return h
        }

        /** Called by DataSource.close(); closes the handle outside the lock. */
        fun closeHandle(h: Long) {
            synchronized(lock) { live.remove(h) }
            CryptoNative.nativePlayerStreamClose(h)
        }

        fun setActive(on: Boolean) {
            synchronized(lock) {
                if (released || active == on) return
                active = on
                for (h in live) CryptoNative.nativePlayerStreamSetActive(h, on)
                if (pending != 0L) CryptoNative.nativePlayerStreamSetActive(pending, on)
            }
        }

        /** Abort live handles; returns an unused pending handle for the caller to close. */
        fun release(): Long {
            synchronized(lock) {
                released = true
                for (h in live) CryptoNative.nativePlayerStreamAbort(h)
                val p = pending
                pending = 0L
                return p
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterBinding = binding
        textureRegistry = binding.textureRegistry
        methodChannel = MethodChannel(binding.binaryMessenger, "shortplay/native_player")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "shortplay/native_player/events")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onAttachedToActivity(binding: io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding) {
        activity = binding.activity
    }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding) {
        activity = binding.activity
    }
    override fun onDetachedFromActivity() { activity = null }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        players.keys.toList().forEach { disposePlayer(it) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                val cdnUrl = call.argument<String>("cdnUrl")!!
                val keyHex = call.argument<String>("keyHex")!!
                handleCreate(cdnUrl, keyHex, result)
            }
            "play" -> {
                val id = call.argument<Int>("id")!!
                players[id]?.player?.play()
                result.success(null)
            }
            "pause" -> {
                val id = call.argument<Int>("id")!!
                players[id]?.player?.pause()
                result.success(null)
            }
            "seek" -> {
                val id = call.argument<Int>("id")!!
                val positionMs = call.argument<Number>("positionMs")!!.toLong()
                players[id]?.player?.seekTo(positionMs)
                result.success(null)
            }
            "setActive" -> {
                val id = call.argument<Int>("id")!!
                val active = call.argument<Boolean>("active") ?: true
                players[id]?.streams?.setActive(active)
                result.success(null)
            }
            "setVolume" -> {
                val id = call.argument<Int>("id")!!
                val volume = call.argument<Number>("volume")!!.toFloat()
                players[id]?.player?.volume = volume
                result.success(null)
            }
            "setRate" -> {
                val id = call.argument<Int>("id")!!
                val rate = call.argument<Number>("rate")!!.toFloat()
                players[id]?.player?.playbackParameters = PlaybackParameters(rate)
                result.success(null)
            }
            "dispose" -> {
                val id = call.argument<Int>("id")!!
                disposePlayer(id)
                result.success(null)
            }
            "setKeepScreenOn" -> {
                val on = call.argument<Boolean>("on") ?: false
                handler.post {
                    activity?.window?.let { w ->
                        if (on) w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleCreate(cdnUrl: String, keyHex: String, result: MethodChannel.Result) {
        val playerId = nextId.getAndIncrement()
        result.success(mapOf("playerId" to playerId, "textureId" to -1))

        if (keyHex.isEmpty()) {
            handler.post {
                try {
                    createPlayerWithUri(playerId, cdnUrl)
                } catch (error: Exception) {
                    disposePlayer(playerId)
                    sendEvent(playerId, "error", error.message ?: "无法打开视频")
                }
            }
        } else {
            CryptoNative.ensureInit()
            backgroundExecutor.execute {
                val streamHandle = CryptoNative.nativePlayerStreamOpen(cdnUrl, keyHex)
                if (streamHandle == 0L) {
                    sendEvent(playerId, "error", "sp_stream_open failed")
                    return@execute
                }
                handler.post { createPlayerWithCrypto(playerId, cdnUrl, keyHex, streamHandle) }
            }
        }
    }

    private fun createPlayerWithUri(playerId: Int, uri: String) {
        val parsedUri = Uri.parse(uri)
        val mediaUri = if (parsedUri.scheme.isNullOrEmpty() || parsedUri.scheme == "file") {
            val file = File(if (parsedUri.scheme == "file") parsedUri.path.orEmpty() else uri)
            require(file.isFile && file.canRead() && file.length() > 0) {
                "本地缓存无法读取，请重新下载"
            }
            Uri.fromFile(file)
        } else {
            parsedUri
        }
        val textureEntry = textureRegistry.createSurfaceTexture()
        val surface = Surface(textureEntry.surfaceTexture())
        val player = ExoPlayer.Builder(flutterBinding.applicationContext).build()
        players[playerId] = PlayerInstance(playerId, player, textureEntry, null, surface)
        setupPlayerListener(playerId, player)
        player.setVideoSurface(surface)

        val mediaItem = MediaItem.fromUri(mediaUri)
        player.setMediaItem(mediaItem)
        player.prepare()

        sendEvent(playerId, "created", textureEntry.id())
    }

    private fun createPlayerWithCrypto(
        playerId: Int, cdnUrl: String, keyHex: String, streamHandle: Long
    ) {
        val textureEntry = textureRegistry.createSurfaceTexture()
        val surface = Surface(textureEntry.surfaceTexture())

        val player = ExoPlayer.Builder(flutterBinding.applicationContext).build()
        player.setVideoSurface(surface)

        val slot = StreamSlot(streamHandle)
        val dataSourceFactory = DataSource.Factory {
            CryptoDataSource(cdnUrl, keyHex, slot)
        }
        val mediaSource = ProgressiveMediaSource.Factory(dataSourceFactory)
            .createMediaSource(MediaItem.fromUri("crypto://$cdnUrl"))
        players[playerId] = PlayerInstance(playerId, player, textureEntry, slot, surface)
        setupPlayerListener(playerId, player)
        player.setMediaSource(mediaSource)
        player.prepare()
        sendEvent(playerId, "created", textureEntry.id())
    }

    private fun setupPlayerListener(playerId: Int, player: ExoPlayer) {
        var firstFrameSent = false

        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                sendEvent(playerId, "error", "${error.errorCodeName}: ${error.cause?.message ?: error.message}")
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> sendEvent(playerId, "buffering", true)
                    Player.STATE_READY -> {
                        sendEvent(playerId, "buffering", false)
                        sendEvent(playerId, "duration", player.duration)
                    }
                    Player.STATE_ENDED -> sendEvent(playerId, "completed", true)
                    Player.STATE_IDLE -> {}
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                sendEvent(playerId, "playing", isPlaying)
                if (isPlaying) {
                    startPositionUpdates(playerId)
                }
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                sendVideoSize(playerId, videoSize)
            }

            override fun onRenderedFirstFrame() {
                if (!firstFrameSent) {
                    firstFrameSent = true
                    // 兜底：确保首帧时 Dart 侧已拿到尺寸（否则按默认 9:16 拉伸）
                    sendVideoSize(playerId, player.videoSize)
                    sendEvent(playerId, "firstFrame", true)
                }
            }
        })
    }

    private val lastVideoSizes = ConcurrentHashMap<Int, Pair<Int, Int>>()

    /** 上报显示尺寸：考虑非正方形像素（pixelWidthHeightRatio），并去重。 */
    private fun sendVideoSize(playerId: Int, videoSize: VideoSize) {
        if (videoSize.width <= 0 || videoSize.height <= 0) return
        val ratio = if (videoSize.pixelWidthHeightRatio > 0f) videoSize.pixelWidthHeightRatio else 1f
        val w = (videoSize.width * ratio).toInt()
        val h = videoSize.height
        if (lastVideoSizes[playerId] == Pair(w, h)) return
        lastVideoSizes[playerId] = Pair(w, h)
        handler.post {
            eventSink?.success(mapOf(
                "playerId" to playerId,
                "type" to "videoSize",
                "width" to w,
                "height" to h
            ))
        }
    }

    private fun startPositionUpdates(playerId: Int) {
        handler.post(object : Runnable {
            override fun run() {
                val instance = players[playerId] ?: return
                val player = instance.player
                if (player.isPlaying) {
                    sendEvent(playerId, "position", player.currentPosition)
                    handler.postDelayed(this, 200)
                }
            }
        })
    }

    private fun sendEvent(playerId: Int, type: String, value: Any) {
        handler.post {
            eventSink?.success(mapOf("playerId" to playerId, "type" to type, "value" to value))
        }
    }

    private fun disposePlayer(id: Int) {
        val instance = players.remove(id) ?: return
        lastVideoSizes.remove(id)
        // Abort first so a loader thread blocked on a parked stream returns
        // and ExoPlayer can release promptly (and close its DataSource).
        val unused = instance.streams?.release() ?: 0L
        instance.player.release()
        instance.surface.release()
        instance.textureEntry.release()
        if (unused != 0L) {
            backgroundExecutor.execute {
                CryptoNative.nativePlayerStreamClose(unused)
            }
        }
    }

    private inner class CryptoDataSource(
        private val cdnUrl: String,
        private val keyHex: String,
        private val slot: StreamSlot
    ) : BaseDataSource(true) {

        private var streamHandle: Long = 0L
        private var uri: Uri? = null
        private var bytesRemaining: Long = C.LENGTH_UNSET.toLong()

        override fun open(dataSpec: DataSpec): Long {
            uri = dataSpec.uri
            streamHandle = slot.acquire(cdnUrl, keyHex)
            val totalSize = CryptoNative.nativePlayerStreamSize(streamHandle)
            if (dataSpec.position > 0) {
                CryptoNative.nativePlayerStreamSeek(streamHandle, dataSpec.position)
            }
            bytesRemaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) {
                dataSpec.length
            } else if (totalSize > 0) {
                totalSize - dataSpec.position
            } else {
                C.LENGTH_UNSET.toLong()
            }
            transferStarted(dataSpec)
            return bytesRemaining
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT
            val toRead = if (bytesRemaining != C.LENGTH_UNSET.toLong()) {
                minOf(length.toLong(), bytesRemaining).toInt()
            } else {
                length
            }
            val tempBuf = ByteArray(toRead)
            val bytesRead = CryptoNative.nativePlayerStreamRead(streamHandle, tempBuf, toRead)
            if (bytesRead <= 0) return C.RESULT_END_OF_INPUT
            System.arraycopy(tempBuf, 0, buffer, offset, bytesRead)
            if (bytesRemaining != C.LENGTH_UNSET.toLong()) {
                bytesRemaining -= bytesRead
            }
            bytesTransferred(bytesRead)
            return bytesRead
        }

        override fun getUri(): Uri? = uri

        override fun close() {
            if (streamHandle != 0L) {
                val h = streamHandle
                streamHandle = 0L
                slot.closeHandle(h)
            }
            transferEnded()
        }
    }
}