package com.shortplay.playback

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min

/** Shared raw-byte format used by Dart prefetch and native playback IO.
 * Cache errors are misses; neither unverified bytes nor incomplete blocks are served.
 */
object MediaByteCache {
    const val BLOCK_SIZE = 32768
    private const val DEFAULT_TTL = 60 * 60 * 1000L
    private const val DEFAULT_BUDGET = 300 * 1024 * 1024L
    private val lock = Any()
    @Volatile private var directory: File? = null
    @Volatile private var lastTrim = 0L
    private val trimPending = AtomicBoolean(false)
    private val maintenance = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ShortplayMediaCacheTrim").apply { isDaemon = true }
    }
    @Volatile var hits = 0L; private set
    @Volatile var hitBytes = 0L; private set
    @Volatile var writtenBytes = 0L; private set

    data class Metadata(val totalLength: Long, val expiresAt: Long, val etag: String?)

    fun configure(root: File): File = synchronized(lock) {
        val canonical = root.canonicalFile
        canonical.mkdirs()
        directory = canonical
        canonical
    }

    fun root(): File? = directory
    fun identity(url: String): String = digest(url.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    private fun digest(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)
    private fun objectDir(url: String): File? = directory?.let { File(it, identity(url)) }
    private fun safe(file: File): Boolean = try { file.canonicalPath == file.absolutePath } catch (_: Exception) { false }

    private fun metadataUnlocked(url: String, allowExpired: Boolean = false): Metadata? {
        val dir = objectDir(url) ?: return null
        val file = File(dir, "meta.json")
        if (!safe(dir) || !safe(file) || !file.isFile || file.length() !in 1..16384) return null
        return try {
            val value = JSONObject(file.readText(Charsets.UTF_8))
            val total = value.optLong("totalLength", -1)
            val expires = value.optLong("expiresAt", -1)
            if (value.optInt("version") != 1 || total <= 0 || (!allowExpired && expires <= System.currentTimeMillis())) null
            else Metadata(total, expires, if (value.isNull("etag")) null else value.optString("etag", "").takeIf { it.isNotEmpty() })
        } catch (_: Exception) { null }
    }

    fun metadata(url: String): Metadata? = synchronized(lock) { metadataUnlocked(url) }

    /** Reads only a contiguous verified prefix, up to maxLength. Empty is never EOF. */
    fun readPrefix(url: String, start: Long, maxLength: Int): ByteArray? = readPrefixInternal(url, start, maxLength, true)

    private fun readPrefixInternal(url: String, start: Long, maxLength: Int, recordHit: Boolean): ByteArray? = synchronized(lock) {
        if (start < 0 || maxLength <= 0) return@synchronized null
        val meta = metadataUnlocked(url) ?: return@synchronized null
        if (start >= meta.totalLength) return@synchronized null
        val dir = objectDir(url) ?: return@synchronized null
        val blocks = File(dir, "blocks")
        if (!safe(blocks)) return@synchronized null
        val wanted = min(maxLength.toLong(), meta.totalLength - start).toInt()
        val output = java.io.ByteArrayOutputStream(wanted)
        var position = start
        try {
            while (output.size() < wanted) {
                val index = position / BLOCK_SIZE
                val blockStart = index * BLOCK_SIZE
                val payloadSize = min(BLOCK_SIZE.toLong(), meta.totalLength - blockStart).toInt()
                val file = File(blocks, "$index.blk")
                if (!safe(file) || !file.isFile || file.length() != payloadSize + 32L) break
                val encoded = file.readBytes()
                val payload = encoded.copyOfRange(32, encoded.size)
                if (!MessageDigest.isEqual(encoded.copyOfRange(0, 32), digest(payload))) {
                    file.delete()
                    break
                }
                val offset = (position - blockStart).toInt()
                val count = min(wanted - output.size(), payload.size - offset)
                output.write(payload, offset, count)
                position += count
                file.setLastModified(System.currentTimeMillis())
            }
            val latest = metadataUnlocked(url)
            if (latest != meta || output.size() == 0) return@synchronized null
            if (recordHit) { hits++; hitBytes += output.size() }
            output.toByteArray()
        } catch (_: Exception) { null }
    }

    fun read(url: String, start: Long, endInclusive: Long): ByteArray? {
        if (endInclusive < start || endInclusive - start >= Int.MAX_VALUE) return null
        val count = (endInclusive - start + 1).toInt()
        val bytes = readPrefixInternal(url, start, count, false)?.takeIf { it.size == count } ?: return null
        synchronized(lock) { hits++; hitBytes += bytes.size }
        return bytes
    }

    private fun atomicWrite(target: File, bytes: ByteArray) {
        target.parentFile?.mkdirs()
        val temporary = File(target.parentFile, ".${target.name}.${UUID.randomUUID()}.tmp")
        try {
            FileOutputStream(temporary).use { stream -> stream.write(bytes) }
            if (!temporary.renameTo(target)) throw java.io.IOException("Atomic cache rename failed")
        } finally { temporary.delete() }
    }

    /** Only call with bytes validated against an origin response's byte interval. */
    fun write(url: String, start: Long, bytes: ByteArray, totalLength: Long,
              etag: String? = null, expiresAt: Long? = null) = synchronized(lock) {
        if (start < 0 || bytes.isEmpty() || totalLength <= 0 || start > totalLength - bytes.size) return@synchronized
        try {
            val dir = objectDir(url) ?: return@synchronized
            if (!safe(dir)) return@synchronized
            val old = metadataUnlocked(url, allowExpired = true)
            val changed = old == null || old.expiresAt <= System.currentTimeMillis() ||
                old.totalLength != totalLength ||
                (old.etag != null && etag != null && old.etag != etag)
            if (changed && dir.exists()) dir.deleteRecursively()
            val expiry = expiresAt ?: old?.expiresAt?.takeIf { !changed } ?: (System.currentTimeMillis() + DEFAULT_TTL)
            if (expiry <= System.currentTimeMillis()) return@synchronized
            val metadata = JSONObject().put("version", 1).put("totalLength", totalLength).put("expiresAt", expiry)
            val effectiveEtag = etag ?: old?.etag?.takeIf { !changed }
            effectiveEtag?.let { metadata.put("etag", it) }
            if (old == null || changed || old.expiresAt != expiry || old.etag != effectiveEtag) {
                atomicWrite(File(dir, "meta.json"), metadata.toString().toByteArray(Charsets.UTF_8))
            }
            val blocks = File(dir, "blocks")
            if (!safe(blocks)) return@synchronized
            var index = (start + BLOCK_SIZE - 1) / BLOCK_SIZE
            while (index * BLOCK_SIZE < start + bytes.size) {
                val blockStart = index * BLOCK_SIZE
                val length = min(BLOCK_SIZE.toLong(), totalLength - blockStart).toInt()
                val offset = blockStart - start
                if (offset < 0 || offset + length > bytes.size) break
                val payload = bytes.copyOfRange(offset.toInt(), offset.toInt() + length)
                atomicWrite(File(blocks, "$index.blk"), digest(payload) + payload)
                writtenBytes += length
                index++
            }
            requestTrim(false)
        } catch (_: Exception) { /* Disk-full/corrupt cache must not break playback. */ }
    }

    fun invalidate(url: String) = synchronized(lock) {
        try { objectDir(url)?.takeIf { safe(it) }?.deleteRecursively() } catch (_: Exception) { }
    }

    /** Maintenance never blocks the main/loader thread or holds the IO lock
     * while walking the directory. Dart also prunes after prefetch completion.
     */
    fun trim() { requestTrim(true) }

    private fun requestTrim(force: Boolean) {
        val now = System.currentTimeMillis()
        if ((!force && now - lastTrim < 2000) || !trimPending.compareAndSet(false, true)) return
        lastTrim = now
        maintenance.execute {
            try { trimFiles() } catch (_: Exception) { } finally { trimPending.set(false) }
        }
    }

    private fun trimFiles() {
        val root = directory ?: return
        val objects = root.listFiles().orEmpty()
            .filter { it.name.matches(Regex("[0-9a-f]{64}")) && safe(it) && it.isDirectory }
        val blocks = objects.flatMap { File(it, "blocks").listFiles().orEmpty().asList() }
            .filter { safe(it) && it.isFile && it.name.matches(Regex("[0-9]+\\.blk")) }
        val metadata = objects.map { File(it, "meta.json") }.filter { safe(it) && it.isFile }
        var total = blocks.sumOf { it.length() } + metadata.sumOf { it.length() }
        if (total <= DEFAULT_BUDGET) return
        for (file in blocks.sortedBy { it.lastModified() }) {
            val size = file.length()
            if (file.delete()) total -= size
            if (total <= DEFAULT_BUDGET) break
        }
        // Empty object metadata must not accumulate beyond the same budget.
        if (total > DEFAULT_BUDGET) {
            for (file in metadata.sortedBy { it.lastModified() }) {
                if (File(file.parentFile, "blocks").listFiles().orEmpty().isNotEmpty()) continue
                val size = file.length()
                if (file.delete()) total -= size
                file.parentFile?.delete()
                if (total <= DEFAULT_BUDGET) break
            }
        }
    }

    /** Assemble complete cache blocks from arbitrarily small streaming reads. */
    class Writer(private val url: String, start: Long, private val total: Long, private val etag: String?) {
        private var position = start
        private var blockStart = start - start % BLOCK_SIZE
        private var output = java.io.ByteArrayOutputStream(BLOCK_SIZE)
        private var eligible = start == blockStart
        fun append(bytes: ByteArray, offset: Int, length: Int) {
            var cursor = offset
            var remaining = length
            while (remaining > 0) {
                val blockLength = min(BLOCK_SIZE.toLong(), total - blockStart).toInt()
                if (blockLength <= 0) return
                val within = (position - blockStart).toInt()
                val count = min(remaining, blockLength - within)
                if (eligible) output.write(bytes, cursor, count)
                position += count; cursor += count; remaining -= count
                if (position == blockStart + blockLength) {
                    if (eligible && output.size() == blockLength) write(url, blockStart, output.toByteArray(), total, etag)
                    blockStart = position; eligible = true; output = java.io.ByteArrayOutputStream(BLOCK_SIZE)
                }
            }
        }
    }
}
