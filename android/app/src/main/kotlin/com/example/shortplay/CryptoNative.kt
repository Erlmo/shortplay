package com.example.shortplay

import android.util.Log
import androidx.annotation.Keep
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.InputStream
import java.io.IOException
import java.io.InterruptedIOException
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
    /** Park (false) / unpark (true) a stream; see sp_stream_set_active. */
    @JvmStatic external fun nativePlayerStreamSetActive(handle: Long, active: Boolean)
    /** Non-blocking: stop the producer and wake a blocked reader. */
    @JvmStatic external fun nativePlayerStreamAbort(handle: Long)
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
        // 文件头请求必须在 Dart 的 15 秒首帧期限内完成或重试。
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .callTimeout(6, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        // Bypass the system/WiFi HTTP proxy and hit the CDN directly. OkHttp
        // defaults to ProxySelector.getDefault(), which picks up a per-network
        // proxy (e.g. a debugging proxy like Charles on 192.168.x.x:8888) and
        // breaks playback when that proxy is unreachable. The Dart proxy path
        // (dart:io HttpClient) connects directly, so match that behavior.
        .proxy(Proxy.NO_PROXY)
        .build()

    // MP4 扫描会连续读取几个 8 字节 box 头。一次读取有界前缀，避免
    // 每个 box 都等待一次 CDN 往返；同一前缀也供首段预热复用。
    private data class Prefix(val bytes: ByteArray, val createdAt: Long)
    private val prefixes = LinkedHashMap<String, Prefix>()
    private const val PREFIX_SIZE = 256 * 1024
    private const val PREFIX_TTL_MS = 30_000L

    private fun cachedRange(url: String, start: Long, end: Long): ByteArray? {
        synchronized(prefixes) {
            val prefix = prefixes[url] ?: return null
            if (android.os.SystemClock.elapsedRealtime() - prefix.createdAt > PREFIX_TTL_MS) {
                prefixes.remove(url)
                return null
            }
            if (start < 0 || end < start || end >= prefix.bytes.size) return null
            return prefix.bytes.copyOfRange(start.toInt(), end.toInt() + 1)
        }
    }

    /** 一个播放器的打开操作共用取消范围，退出时立即关闭等待中的请求。 */
    class RequestScope {
        @Volatile private var cancelled = false
        private val calls = ConcurrentHashMap.newKeySet<Call>()
        fun ensureActive() {
            if (cancelled || Thread.currentThread().isInterrupted) {
                throw InterruptedIOException("Playback request cancelled")
            }
        }
        fun register(call: Call) {
            calls.add(call)
            if (cancelled) call.cancel()
        }
        fun remove(call: Call) { calls.remove(call) }
        fun cancel() {
            cancelled = true
            calls.forEach { it.cancel() }
        }
    }

    private val requestScope = ThreadLocal<RequestScope>()

    fun <T> withRequestScope(scope: RequestScope, action: () -> T): T {
        val previous = requestScope.get()
        requestScope.set(scope)
        try {
            scope.ensureActive()
            return action()
        } finally {
            if (previous == null) requestScope.remove() else requestScope.set(previous)
        }
    }

    /** 有界 Range 读取；瞬时 CDN 故障自动重试一次，不在取消后继续请求。 */
    @JvmStatic
    fun httpRange(url: String, start: Long, end: Long): ByteArray? {
        val scope = requestScope.get()
        try { scope?.ensureActive() } catch (_: InterruptedIOException) { return null }
        if (start < 0 || end < start || end - start >= Int.MAX_VALUE) return null
        cachedRange(url, start, end)?.let { return it }
        val fetchPrefix = start == 0L && end <= 15L
        val requestEnd = if (fetchPrefix) PREFIX_SIZE - 1L else end
        val request = Request.Builder().url(url)
            .header("Range", "bytes=$start-$requestEnd").build()
        val wanted = (requestEnd - start + 1).toInt()
        repeat(2) { attempt ->
            try { scope?.ensureActive() } catch (_: InterruptedIOException) { return null }
            if (Thread.currentThread().isInterrupted) return null
            val call = client.newCall(request)
            scope?.register(call)
            val clock = android.os.SystemClock.elapsedRealtime()
            try {
                val bytes = call.execute().use { response ->
                    if (!response.isSuccessful) throw IOException("CDN HTTP ${response.code}")
                    // Range 被忽略时不能把整个文件当作非零偏移的片段。
                    if ((response.code == 200 && start != 0L) ||
                        (response.code == 206 && !response.header("Content-Range", "")!!
                            .startsWith("bytes $start-"))) {
                        throw IOException("Invalid CDN range response")
                    }
                    val input = response.body?.byteStream() ?: throw IOException("Empty CDN body")
                    val output = java.io.ByteArrayOutputStream(minOf(wanted, PREFIX_SIZE))
                    val buffer = ByteArray(minOf(16 * 1024, wanted))
                    while (output.size() < wanted) {
                        val n = input.read(buffer, 0, minOf(buffer.size, wanted - output.size()))
                        if (n < 0) break
                        if (n == 0) throw IOException("Empty CDN read")
                        output.write(buffer, 0, n)
                    }
                    output.toByteArray()
                }
                if (bytes.size < end - start + 1) throw IOException("Truncated CDN range")
                if (fetchPrefix) {
                    synchronized(prefixes) {
                        prefixes[url] = Prefix(bytes, android.os.SystemClock.elapsedRealtime())
                        while (prefixes.size > 4) prefixes.remove(prefixes.keys.first())
                    }
                }
                Log.d("PlaybackNetwork", "host=${request.url.host} range=$start-$requestEnd " +
                    "attempt=${attempt + 1} bytes=${bytes.size} elapsed_ms=" +
                    (android.os.SystemClock.elapsedRealtime() - clock))
                return if (fetchPrefix) bytes.copyOfRange(0, end.toInt() + 1) else bytes
            } catch (error: IOException) {
                if (call.isCanceled() || Thread.currentThread().isInterrupted) {
                    // callTimeout 也会把 Call 标记为取消；播放器取消由 scope 单独判断。
                    try { scope?.ensureActive() } catch (_: InterruptedIOException) { return null }
                    if (Thread.currentThread().isInterrupted) return null
                }
                Log.w("PlaybackNetwork", "host=${request.url.host} range=$start-$requestEnd " +
                    "attempt=${attempt + 1} elapsed_ms=" +
                    (android.os.SystemClock.elapsedRealtime() - clock) + " error=${error.javaClass.simpleName}")
                // 只清理空闲连接，避免再次借用已失效的连接；不关闭正在播放的流。
                client.connectionPool.evictAll()
            } finally {
                scope?.remove(call)
            }
        }
        return null
    }

    // ── Streaming GET (used for the mdat region) ────────────────────────────
    // An open-ended `Range: bytes=start-` request whose body is read chunk by
    // chunk, so the native producer can hand each arriving TCP segment to mpv
    // immediately — the same shape as the Dart proxy's Dio stream + await-for.
    private class Stream(val resp: Response, val input: InputStream)

    private val streams = ConcurrentHashMap<Long, Stream>()
    private val nextId = AtomicLong(1L)
    // 流式正文不能继承文件头的整次调用期限，否则播放六秒就会被取消。
    // readTimeout 只约束实际阻塞读取，不影响播放器暂停时不读取的连接。
    private val streamClient: OkHttpClient = client.newBuilder()
        .callTimeout(0, TimeUnit.SECONDS)
        .readTimeout(6, TimeUnit.SECONDS)
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
            body.source().timeout().timeout(8, TimeUnit.SECONDS)
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
