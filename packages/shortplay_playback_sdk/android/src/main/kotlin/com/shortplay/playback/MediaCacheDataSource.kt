package com.shortplay.playback

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit
import java.net.Proxy
import kotlin.math.min

/** Ordinary MP4 raw IO shares the exact same candidate/retry/cache policy as
 * encrypted reads. Extractors, renderer and decoder remain owned by the host. */
class MediaCacheDataSource(private val factory: DataSource.Factory) : DataSource {
    class Factory(context: Context) : DataSource.Factory {
        private val upstream = DefaultDataSource.Factory(context,
            DefaultHttpDataSource.Factory().setDefaultRequestProperties(mapOf("Accept-Encoding" to "identity")))
        override fun createDataSource(): DataSource = MediaCacheDataSource(upstream)
    }
    companion object {
        private val client = OkHttpClient.Builder().connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(8, TimeUnit.SECONDS).callTimeout(0, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false).proxy(Proxy.NO_PROXY).build()
    }
    private val listeners = mutableListOf<TransferListener>()
    private var spec: DataSpec? = null
    @Volatile private var reader: MediaNetworkReader? = null
    private var upstream: DataSource? = null
    private var pendingByte: Byte? = null
    private var opened = false
    private var position = 0L
    private var remaining = C.LENGTH_UNSET.toLong()
    override fun addTransferListener(listener: TransferListener) {
        listeners.add(listener)
        upstream?.addTransferListener(listener)
    }
    override fun open(dataSpec: DataSpec): Long {
        close()
        spec = dataSpec
        position = dataSpec.position
        val scheme = dataSpec.uri.scheme
        val path = dataSpec.uri.path.orEmpty().lowercase()
        val eligible = (scheme == "http" || scheme == "https") &&
            !path.endsWith(".m3u8") && !path.endsWith(".mpd") &&
            dataSpec.httpMethod == DataSpec.HTTP_METHOD_GET && dataSpec.httpRequestHeaders.isEmpty()
        if (!eligible) {
            val source = factory.createDataSource()
            upstream = source
            listeners.forEach { source.addTransferListener(it) }
            return source.open(dataSpec)
        }
        listeners.forEach { it.onTransferInitializing(this, dataSpec, true) }
        val knownTotal = MediaByteCache.metadata(dataSpec.uri.toString())?.totalLength
        remaining = when {
            dataSpec.length != C.LENGTH_UNSET.toLong() -> dataSpec.length
            knownTotal != null -> (knownTotal - dataSpec.position).coerceAtLeast(0)
            else -> C.LENGTH_UNSET.toLong()
        }
        val raw = MediaNetworkReader(dataSpec.uri.toString(), dataSpec.position, client,
            if (dataSpec.length > 0) dataSpec.position + dataSpec.length - 1 else null)
        reader = raw // close() can cancel the priming request before headers.
        if (remaining == C.LENGTH_UNSET.toLong()) {
            try {
                val first = ByteArray(1)
                val count = raw.read(first)
                if (count > 0) pendingByte = first[0]
                remaining = raw.totalLength?.let { (it - dataSpec.position).coerceAtLeast(0) }
                    ?: if (count < 0) 0 else C.LENGTH_UNSET.toLong()
            } catch (error: MediaNetworkFailure) {
                if (!error.rangeUnsupported) { close(); throw error }
                // Keep DefaultHttpDataSource's existing single-URL range-ignore
                // compatibility (skip the requested prefix) for ordinary MP4.
                return fallbackWithoutRange(raw.currentUrl)
            } catch (error: java.io.IOException) { close(); throw error }
        }
        opened = true
        listeners.forEach { it.onTransferStart(this, dataSpec, true) }
        return remaining
    }
    private fun fallbackWithoutRange(actual: String): Long {
        val original = spec ?: throw java.io.IOException("Missing media request")
        reader?.close(); reader = null; pendingByte = null
        if (opened) {
            opened = false
            listeners.forEach { it.onTransferEnd(this, original, true) }
        }
        val source = factory.createDataSource()
        upstream = source
        listeners.forEach { source.addTransferListener(it) }
        return source.open(original.subrange(position - original.position, remaining).withUri(Uri.parse(actual)))
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        upstream?.let { return it.read(buffer, offset, length) }
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        pendingByte?.let { byte ->
            pendingByte = null
            buffer[offset] = byte
            if (remaining > 0) remaining--
            position++
            spec?.let { dataSpec -> listeners.forEach { it.onBytesTransferred(this, dataSpec, true, 1) } }
            return 1
        }
        val count = try {
            reader?.read(buffer, offset,
                if (remaining >= 0) min(remaining, length.toLong()).toInt() else length)
                ?: return C.RESULT_END_OF_INPUT
        } catch (error: MediaNetworkFailure) {
            if (!error.rangeUnsupported) throw error
            val actual = reader?.currentUrl ?: throw error
            fallbackWithoutRange(actual)
            return upstream!!.read(buffer, offset, length)
        }
        if (count < 0) return C.RESULT_END_OF_INPUT
        if (remaining >= 0) remaining -= count
        position += count
        spec?.let { dataSpec -> listeners.forEach { it.onBytesTransferred(this, dataSpec, true, count) } }
        return count
    }
    override fun getUri(): Uri? = upstream?.uri ?: reader?.let { Uri.parse(it.currentUrl) } ?: spec?.uri
    override fun getResponseHeaders(): Map<String, List<String>> = upstream?.responseHeaders ?: reader?.responseHeaders ?: emptyMap()
    override fun close() {
        reader?.close(); reader = null; pendingByte = null
        try { upstream?.close() } finally {
            upstream = null
            val old = spec
            spec = null
            remaining = C.LENGTH_UNSET.toLong()
            if (opened) {
                opened = false
                if (old != null) listeners.forEach { it.onTransferEnd(this, old, true) }
            }
        }
    }
}
