package com.shortplay.playback

import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.EOFException
import java.net.ProtocolException
import javax.net.ssl.SSLException
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.URI
import java.security.MessageDigest
import kotlin.math.min

/** Authoritative alternatives for ONE rendition. No hostname rewriting or
 * cross-URL cache aliasing. Each reader captures its own immutable route list. */
object NetworkRoutes {
    private data class Entry(val urls: List<String>, val expiresAt: Long, val preferred: String, val version: Long)
    private class Snapshot(private val values: List<String>, val version: Long) : AbstractList<String>() {
        override val size: Int get() = values.size
        override fun get(index: Int): String = values[index]
    }
    private var version = 0L
    private val entries = LinkedHashMap<String, Entry>(64, 0.75f, true)
    private fun valid(url: String): Boolean = try {
        val uri = URI(url)
        (uri.scheme == "https" || uri.scheme == "http") &&
            !uri.host.isNullOrEmpty() && uri.rawUserInfo == null && uri.fragment == null
    } catch (_: Exception) { false }

    @Synchronized fun register(primary: String, urls: List<String>, expiresAt: Long?) {
        require(valid(primary)) { "Invalid primary media URL" }
        require(urls.size <= 4 && urls.all(::valid)) { "Invalid media alternatives" }
        val expiry = expiresAt ?: (System.currentTimeMillis() + 60 * 60 * 1000L)
        if (expiry <= System.currentTimeMillis()) { entries.remove(primary); return }
        val captured = (listOf(primary) + urls).distinct().take(4).toList()
        val old = entries[primary]
        val preferred = if (old?.urls == captured && old.preferred in captured) old.preferred else primary
        entries[primary] = Entry(captured, expiry, preferred, if (old?.urls == captured) old.version else ++version)
        while (entries.size > 64) entries.remove(entries.keys.first())
    }

    @Synchronized fun capture(primary: String): List<String> {
        val entry = entries[primary] ?: return listOf(primary)
        if (entry.expiresAt <= System.currentTimeMillis()) {
            entries.remove(primary)
            return listOf(primary)
        }
        return Snapshot((listOf(entry.preferred) + entry.urls.filter { it != entry.preferred }).toList(), entry.version)
    }

    @Synchronized fun succeeded(primary: String, actual: String, captured: List<String>) {
        val entry = entries[primary] ?: return
        if (entry.expiresAt <= System.currentTimeMillis() || actual !in entry.urls ||
            captured !is Snapshot || entry.version != captured.version) return
        entries[primary] = entry.copy(preferred = actual)
    }
}

class MediaNetworkFailure(message: String, val terminal: Boolean = true,
    val status: Int? = null, val rangeUnsupported: Boolean = false) : IOException(message)

/** Raw media IO only: decoder/renderer never change. Data read failures resume
 * from actual delivered bytes. HTTP 4xx/5xx disables that route for this reader.
 * Three consecutive failed data attempts (at least one round of all routes)
 * is our bounded budget. Valid short 206 windows are progress, not retries. */
class MediaNetworkReader(
    private val primary: String,
    start: Long,
    private val client: OkHttpClient,
    private val endInclusive: Long? = null,
    private val ensureActive: () -> Unit = {},
    private val registerCall: (Call) -> Unit = {},
    private val removeCall: (Call) -> Unit = {},
    private val routes: List<String> = NetworkRoutes.capture(primary)
) {
    private val initialPosition = start
    private val forbidden = BooleanArray(routes.size)
    private var routeIndex = 0
    private var failures = 0
    private val failureBudget = maxOf(3, routes.size)
    private var position = start
    private var anchorOrigin = routes.first()
    private var total = MediaByteCache.metadata(anchorOrigin)?.totalLength
    private var expectedEtag = strong(MediaByteCache.metadata(anchorOrigin)?.etag)
    private var expectedPrefix: ByteArray? = null
    private val prefix = ByteArrayOutputStream(MediaByteCache.BLOCK_SIZE)
    private var verifiedIndex = 0
    private val validated = mutableSetOf<Int>()
    private val validationAttempted = mutableSetOf<Int>()
    @Volatile private var closed = false
    @Volatile private var call: Call? = null
    @Volatile private var response: Response? = null
    private var input: InputStream? = null
    private var remaining = -1L
    private var writer: MediaByteCache.Writer? = null
    private var writerUrl: String? = null
    private val validators = mutableMapOf<String, String?>()
    private var cacheReading = true
    val currentUrl: String get() = routes[routeIndex]
    val totalLength: Long? get() = total
    val contentEtag: String? get() = response?.header("ETag")
    val responseHeaders: Map<String, List<String>> get() = response?.headers?.toMultimap() ?: emptyMap()

    init {
        require(start >= 0 && (endInclusive == null || endInclusive >= start))
        require(routes.isNotEmpty() && primary in routes)
        capturePrefixFromCache(anchorOrigin)
    }

    private fun active() {
        if (closed || Thread.currentThread().isInterrupted) throw InterruptedIOException("Media request cancelled")
        ensureActive()
    }
    private fun strong(value: String?): String? = value?.trim()?.takeIf {
        !it.startsWith("W/", true) && it.length >= 2 && it.first() == '"' && it.last() == '"'
    }
    private fun hash(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
    private fun anchorSize(): Int? = total?.let { min(MediaByteCache.BLOCK_SIZE.toLong(), it).toInt() }
    private fun capturePrefixFromCache(url: String) {
        val size = anchorSize() ?: return
        if (expectedPrefix == null) MediaByteCache.read(url, 0, size - 1L)?.let { expectedPrefix = hash(it) }
    }

    private fun consume(bytes: ByteArray, offset: Int, count: Int) {
        if (position == prefix.size().toLong() && prefix.size() < MediaByteCache.BLOCK_SIZE) {
            prefix.write(bytes, offset, min(count, MediaByteCache.BLOCK_SIZE - prefix.size()))
            val size = anchorSize()
            if (size != null && prefix.size() >= size) expectedPrefix = hash(prefix.toByteArray().copyOf(size))
        }
        position += count
        NetworkRoutes.succeeded(primary, currentUrl, routes)
        failures = 0 // Forward progress ends the consecutive failure chain.
    }

    private fun execute(url: String, start: Long, end: Long?): Response {
        active()
        val request = Request.Builder().url(url)
            .header("Range", "bytes=$start-${end?.toString().orEmpty()}")
            .header("Accept-Encoding", "identity").build()
        val pending = client.newCall(request)
        call = pending
        registerCall(pending)
        active()
        val result = try { pending.execute() } catch (error: IOException) {
            removeCall(pending)
            throw error
        }
        response = result
        active()
        return result
    }

    private data class Bounds(val total: Long, val length: Long)
    private fun bounds(result: Response, start: Long, end: Long?): Bounds {
        if (result.code in 400..599) throw MediaNetworkFailure("CDN HTTP ${result.code}", false, result.code)
        if (!result.header("Content-Encoding").orEmpty().let { it.isEmpty() || it.equals("identity", true) }) {
            throw MediaNetworkFailure("Compressed media byte range")
        }
        val body = result.body ?: throw MediaNetworkFailure("Missing media body")
        if (result.code == 206) {
            val m = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(result.header("Content-Range").orEmpty())
                ?: throw MediaNetworkFailure("Invalid media Content-Range")
            val first = m.groupValues[1].toLongOrNull()
            val last = m.groupValues[2].toLongOrNull()
            val size = m.groupValues[3].toLongOrNull()
            if (first != start || last == null || size == null || last < start || last >= size ||
                (end != null && last > end) ||
                (body.contentLength() >= 0 && body.contentLength() != last - start + 1)) {
                throw MediaNetworkFailure("Mismatched media range")
            }
            return Bounds(size, last - start + 1)
        }
        if (result.code == 200 && start == 0L && body.contentLength() > 0) {
            return Bounds(body.contentLength(), body.contentLength())
        }
        throw MediaNetworkFailure("Unsupported media response", rangeUnsupported = result.code == 200 && start > 0)
    }

    private fun clearResponse() {
        val pending = call
        try { response?.close() } catch (_: Exception) { }
        if (pending != null) removeCall(pending)
        input = null; response = null; call = null; remaining = -1L
    }

    /** A candidate validation has one bounded 32KiB request, never a retry loop.
     * Its bytes are not delivered. It uses the same cancellation scope. */
    private fun validateRoute() {
        if (routeIndex == verifiedIndex || validated.contains(routeIndex)) return
        if (position == initialPosition && prefix.size() == 0 && total == null && expectedEtag == null && expectedPrefix == null) {
            // No byte from the first endpoint has been exposed to the caller.
            total = null; expectedEtag = null; expectedPrefix = null
            anchorOrigin = currentUrl
            verifiedIndex = routeIndex
            return
        }
        capturePrefixFromCache(anchorOrigin)
        val expected = expectedPrefix
        val size = anchorSize()
        if (expectedEtag == null && (expected == null || size == null)) {
            throw MediaNetworkFailure("No anchor for CDN continuation")
        }
        if (!validationAttempted.add(routeIndex)) throw MediaNetworkFailure("CDN anchor already failed")
        val result = try {
            execute(currentUrl, 0, (size ?: MediaByteCache.BLOCK_SIZE) - 1L)
        } catch (error: IOException) {
            forbidden[routeIndex] = true
            throw error
        }
        try {
            val b = bounds(result, 0, (size ?: MediaByteCache.BLOCK_SIZE) - 1L)
            if (total != b.total) throw MediaNetworkFailure("CDN content length changed")
            val candidateEtag = strong(result.header("ETag"))
            if (expectedEtag == null || candidateEtag != expectedEtag) {
                if (expected == null || size == null) throw MediaNetworkFailure("No comparable CDN content anchor")
                val data = ByteArray(size)
                val stream = result.body!!.byteStream()
                var done = 0
                while (done < size) {
                    active()
                    val n = stream.read(data, done, size - done)
                    if (n <= 0) throw MediaNetworkFailure("Truncated CDN anchor")
                    done += n
                }
                if (!MessageDigest.isEqual(expected, hash(data))) throw MediaNetworkFailure("CDN content anchor differs")
            }
            result.header("ETag")?.let { validators[currentUrl] = it }
            validated.add(routeIndex)
            verifiedIndex = routeIndex
        } catch (error: IOException) {
            forbidden[routeIndex] = true
            throw error
        } finally { clearResponse() }
    }

    private fun openNetwork() {
        validateRoute()
        val result = execute(currentUrl, position, endInclusive)
        val b = bounds(result, position, endInclusive)
        val meta = MediaByteCache.metadata(currentUrl)
        val etag = result.header("ETag")
        val seenValidator = validators[currentUrl]
        if (seenValidator != null && etag != null && seenValidator != etag) {
            MediaByteCache.invalidate(currentUrl)
            throw MediaNetworkFailure("Media validator changed during resume")
        }
        if (etag != null) validators[currentUrl] = etag
        if (total != null && total != b.total) {
            MediaByteCache.invalidate(currentUrl)
            throw MediaNetworkFailure("Media content length changed")
        }
        if (meta != null && (meta.totalLength != b.total ||
            (meta.etag != null && etag != null && meta.etag != etag))) {
            MediaByteCache.invalidate(currentUrl)
            throw MediaNetworkFailure("Media content validator changed")
        }
        if (currentUrl == anchorOrigin && expectedEtag != null && strong(etag) != null && expectedEtag != strong(etag)) {
            MediaByteCache.invalidate(currentUrl)
            throw MediaNetworkFailure("Media content changed")
        }
        total = b.total
        if (expectedEtag == null && routeIndex == verifiedIndex) expectedEtag = strong(etag)
        capturePrefixFromCache(currentUrl)
        remaining = min(b.length, endInclusive?.let { it - position + 1 } ?: b.length)
        // HTTP 200 prefix cannot establish Range support for other adapters.
        if (result.code != 206) {
            writer = null; writerUrl = null
        } else if (writer == null || writerUrl != currentUrl) {
            writer = MediaByteCache.Writer(currentUrl, position, b.total, etag)
            writerUrl = currentUrl
        }
        input = result.body!!.byteStream()
    }

    private fun handle(error: IOException) {
        clearResponse()
        active()
        if (error is MediaNetworkFailure && error.terminal) throw error
        if (generateSequence<Throwable>(error) { it.cause }.any { it is SSLException || it is java.security.cert.CertificateException }) {
            throw MediaNetworkFailure("TLS media request failed")
        }
        if (error is ProtocolException && error.message != "unexpected end of stream") {
            throw MediaNetworkFailure("Invalid HTTP media protocol")
        }
        failures++
        if (error is MediaNetworkFailure && error.status in 400..599) forbidden[routeIndex] = true
        if (failures >= failureBudget) throw MediaNetworkFailure("Media retry budget exhausted")
        val next = (1..routes.size).map { (routeIndex + it) % routes.size }.firstOrNull { !forbidden[it] }
            ?: throw MediaNetworkFailure("All media routes failed")
        // Without an anchor, only resuming the exact same URL is safe.
        capturePrefixFromCache(anchorOrigin)
        if (next != routeIndex && position > initialPosition && expectedEtag == null && expectedPrefix == null) {
            if (forbidden[routeIndex]) throw MediaNetworkFailure("No safe CDN continuation anchor")
        } else {
            if (routeIndex != next) { writer = null; writerUrl = null }
            routeIndex = next
        }
        cacheReading = true
    }

    fun read(buffer: ByteArray, offset: Int = 0, length: Int = buffer.size - offset): Int {
        require(offset >= 0 && length >= 0 && offset <= buffer.size - length)
        active()
        if (length == 0) return 0
        while (true) {
            active()
            if ((total != null && position >= total!!) || (endInclusive != null && position > endInclusive)) return -1
            val limit = min(length.toLong(), endInclusive?.let { it - position + 1 } ?: length.toLong()).toInt()
            try {
                if (input == null) {
                    validateRoute()
                    if (cacheReading) {
                        val cached = MediaByteCache.readPrefix(currentUrl, position, limit)
                        if (cached != null) {
                            val meta = MediaByteCache.metadata(currentUrl)
                            if (total == null) total = meta?.totalLength
                            if (expectedEtag == null && routeIndex == verifiedIndex) expectedEtag = strong(meta?.etag)
                            capturePrefixFromCache(currentUrl)
                            writer?.append(cached, 0, cached.size)
                            System.arraycopy(cached, 0, buffer, offset, cached.size)
                            consume(buffer, offset, cached.size)
                            return cached.size
                        }
                    }
                    openNetwork()
                }
                if (remaining == 0L) { clearResponse(); continue }
                val count = input!!.read(buffer, offset, min(limit.toLong(), remaining).toInt())
                if (count <= 0) throw EOFException("Truncated media body")
                active()
                writer?.append(buffer, offset, count)
                remaining -= count
                consume(buffer, offset, count)
                return count
            } catch (error: IOException) { handle(error) }
        }
    }

    fun close() {
        closed = true
        call?.cancel()
        try { response?.close() } catch (_: Exception) { }
        call?.let(removeCall)
        writer = null
        MediaByteCache.trim()
    }
}
