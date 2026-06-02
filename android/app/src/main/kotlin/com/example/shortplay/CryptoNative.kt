package com.example.shortplay

import android.util.Log
import androidx.annotation.Keep
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.InputStream
import java.net.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Native crypto bridge. Loads the shared library, installs the OkHttp-backed
 * HTTP range fetcher into the C core, and exposes registration of the
 * "crypto://" libmpv protocol against a media_kit Player handle.
 *
 * The C core is dependency-free; all network I/O funnels back through
 * [HttpBridge.httpRange], which libmpv invokes synchronously on its own
 * native thread (already attached to the JVM by the JNI layer).
 */
@Keep
object CryptoNative {
    @Volatile private var initialized = false

    init {
        System.loadLibrary("shortplay_crypto")
    }

    /** Cache the HttpBridge class on the native side. Idempotent. */
    @Synchronized
    fun ensureInit() {
        if (initialized) return
        initialized = nativeInit(HttpBridge::class.java)
    }

    /**
     * Register "crypto://" on the given mpv handle (from Player.handle).
     * Returns 0 on success; non-zero on failure (see C: 1=bad handle,
     * 2=libmpv symbol missing, other=mpv error).
     */
    fun registerCryptoProtocol(handle: Long): Int {
        ensureInit()
        return nativeRegisterCryptoProtocol(handle)
    }

    /**
     * Prewarm the cache for [cdnUrl] so the next playback of it skips the
     * ~300-680ms box scan + header fetch + sample parse. Blocking (does its own
     * range fetches); call from a background thread. Returns 0 on success or
     * already-cached, non-zero on failure.
     */
    fun prewarm(cdnUrl: String, keyHex: String): Int {
        ensureInit()
        return nativePrewarm(cdnUrl, keyHex)
    }

    fun prewarmHeaderOnly(cdnUrl: String, keyHex: String): Int {
        ensureInit()
        return nativePrewarmHeaderOnly(cdnUrl, keyHex)
    }

    fun prewarmSeedMdat(cdnUrl: String): Int {
        ensureInit()
        return nativePrewarmSeedMdat(cdnUrl)
    }

    fun decryptToFile(cdnUrl: String, keyHex: String, outputPath: String): Int {
        ensureInit()
        return nativeDecryptToFile(cdnUrl, keyHex, outputPath)
    }

    private external fun nativeInit(bridge: Class<*>): Boolean
    private external fun nativeRegisterCryptoProtocol(handle: Long): Int
    private external fun nativePrewarm(cdnUrl: String, keyHex: String): Int
    private external fun nativePrewarmHeaderOnly(cdnUrl: String, keyHex: String): Int
    private external fun nativePrewarmSeedMdat(cdnUrl: String): Int
    private external fun nativeDecryptToFile(cdnUrl: String, keyHex: String, outputPath: String): Int

    // ExoPlayer DataSource stream methods
    @JvmStatic external fun nativePlayerStreamOpen(url: String, keyHex: String): Long
    @JvmStatic external fun nativePlayerStreamRead(handle: Long, buf: ByteArray, len: Int): Int
    @JvmStatic external fun nativePlayerStreamSeek(handle: Long, offset: Long): Long
    @JvmStatic external fun nativePlayerStreamSize(handle: Long): Long
    @JvmStatic external fun nativePlayerStreamClose(handle: Long)
}

/**
 * OkHttp-backed HTTP range fetcher invoked from native code. Kept as a
 * top-level object with a single static-style entry point so the JNI layer
 * can resolve it via GetStaticMethodID without holding an instance.
 *
 * Returns the response body bytes, or null on any error (the C core treats
 * null/short reads as a fetch failure and aborts the stream cleanly).
 */
@Keep
object HttpBridge {
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        // Bypass the system/WiFi HTTP proxy and hit the CDN directly. OkHttp
        // defaults to ProxySelector.getDefault(), which picks up a per-network
        // proxy (e.g. a debugging proxy like Charles on 192.168.x.x:8888) and
        // breaks playback when that proxy is unreachable. The Dart proxy path
        // (dart:io HttpClient) connects directly, so match that behavior.
        .proxy(Proxy.NO_PROXY)
        .build()

    /**
     * Blocking GET of [url] with an inclusive Range header bytes=[start]-[end].
     * Called on libmpv's native thread (already JVM-attached by JNI).
     */
    @JvmStatic
    fun httpRange(url: String, start: Long, end: Long): ByteArray? {
        return try {
            val req = Request.Builder()
                .url(url)
                .header("Range", "bytes=$start-$end")
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    Log.e("sp_crypto", "httpRange HTTP ${resp.code} for $url [$start-$end]")
                    return null
                }
                resp.body?.bytes()
            }
        } catch (t: Throwable) {
            Log.e("sp_crypto", "httpRange threw for $url [$start-$end]: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    // ── Streaming GET (used for the mdat region) ────────────────────────────
    // An open-ended `Range: bytes=start-` request whose body is read chunk by
    // chunk, so the native producer can hand each arriving TCP segment to mpv
    // immediately — the same shape as the Dart proxy's Dio stream + await-for.
    private class Stream(val resp: Response, val input: InputStream)

    private val streams = ConcurrentHashMap<Long, Stream>()
    private val nextId = AtomicLong(1L)
    // Separate client: no read timeout, since a streamed body stays open and
    // may idle between chunks while the window is full (TCP backpressure).
    private val streamClient: OkHttpClient = client.newBuilder()
        .readTimeout(0, TimeUnit.SECONDS)
        .build()

    /** Open a streamed GET at [start]. Returns a stream id, or 0 on failure. */
    @JvmStatic
    fun streamOpen(url: String, start: Long): Long {
        return try {
            val req = Request.Builder()
                .url(url)
                .header("Range", "bytes=$start-")
                .build()
            val resp = streamClient.newCall(req).execute()
            val body = resp.body
            if (!resp.isSuccessful || body == null) {
                Log.e("sp_crypto", "streamOpen HTTP ${resp.code} for $url @$start")
                resp.close()
                return 0L
            }
            val id = nextId.getAndIncrement()
            streams[id] = Stream(resp, body.byteStream())
            id
        } catch (t: Throwable) {
            Log.e("sp_crypto", "streamOpen threw @$start: ${t.javaClass.simpleName}: ${t.message}")
            0L
        }
    }

    /**
     * Read the next chunk into [buf]. Returns bytes read (>0), 0 on clean EOF,
     * or -1 on error. A single InputStream.read returns whatever has already
     * arrived, so callers get the first bytes without waiting for a full block.
     */
    @JvmStatic
    fun streamRead(id: Long, buf: ByteArray): Int {
        val s = streams[id] ?: return -1
        return try {
            s.input.read(buf)  // -1 at EOF, mapped below to 0 for the C core
                .let { if (it < 0) 0 else it }
        } catch (t: Throwable) {
            Log.e("sp_crypto", "streamRead threw id=$id: ${t.javaClass.simpleName}: ${t.message}")
            -1
        }
    }

    /** Close and release a stream opened by [streamOpen]. */
    @JvmStatic
    fun streamClose(id: Long) {
        val s = streams.remove(id) ?: return
        try {
            s.resp.close()  // also closes the body / underlying stream
        } catch (_: Throwable) {
        }
    }
}
