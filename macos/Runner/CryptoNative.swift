import Foundation

// MARK: - CryptoNativePlugin

/// Singleton that manages the native crypto bridge lifecycle and stream registry.
final class CryptoNativePlugin {
    static let shared = CryptoNativePlugin()
    private init() {}

    private var initialized = false
    private var streams: [Int64: MediaCachedStream] = [:]
    private var nextStreamId: Int64 = 1
    private let lock = NSLock()

    // MARK: Initialization

    func ensureInit() {
        guard !initialized else { return }
        initialized = true
        sp_ios_init(iosHttpRange, iosStreamOpen, iosStreamRead, iosStreamClose)
    }

    // MARK: Public API (called from MethodChannel)

    func registerCryptoProtocol(handle: Int64) -> Int32 {
        ensureInit()
        return sp_register_crypto_protocol(handle)
    }

    func prewarm(cdnUrl: String, keyHex: String) -> Int32 {
        ensureInit()
        return sp_prewarm(cdnUrl, keyHex)
    }

    func prewarmHeaderOnly(cdnUrl: String, keyHex: String) -> Int32 {
        ensureInit()
        return sp_prewarm_header_only(cdnUrl, keyHex)
    }

    func prewarmSeedMdat(cdnUrl: String) -> Int32 {
        ensureInit()
        return sp_prewarm_seed_mdat(cdnUrl)
    }

    func decryptToFile(cdnUrl: String, keyHex: String,
                       outputPath: String) -> Int32 {
        ensureInit()
        return sp_decrypt_to_file(cdnUrl, keyHex, outputPath)
    }

    // MARK: Stream Registry (called from C callbacks)

    func openStream(url: String, start: UInt64) -> Int64 {
        guard start <= UInt64(Int64.max) else { return 0 }
        let ctx = MediaCachedStream(url: url, start: Int64(start))
        lock.lock()
        let streamId = nextStreamId
        nextStreamId += 1
        streams[streamId] = ctx
        lock.unlock()
        return streamId
    }

    func readStream(id: Int64, buf: UnsafeMutablePointer<UInt8>,
                    capacity: Int) -> Int {
        lock.lock()
        guard let ctx = streams[id] else {
            lock.unlock()
            return -1
        }
        lock.unlock()
        return ctx.read(into: buf, count: capacity)
    }

    func closeStream(id: Int64) {
        lock.lock()
        guard let ctx = streams.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        ctx.cancel()
    }
}

// MARK: - C Callback Functions

/// Synchronous HTTP range fetch. Called from libmpv's native thread.
/// Uses DispatchSemaphore to block until URLSession completes.
private func iosHttpRange(
    _ user: UnsafeMutableRawPointer?,
    _ url: UnsafePointer<CChar>?,
    _ start: UInt64,
    _ end: UInt64,
    _ out: UnsafeMutablePointer<UInt8>?,
    _ outCap: Int
) -> Int {
    guard let url = url, let out = out else { return -1 }
    let urlStr = String(cString: url)
    guard start <= UInt64(Int64.max), end >= start,
          end - start < UInt64(Int.max), !Thread.isMainThread else { return -1 }
    let wanted = min(outCap, Int(end - start + 1))
    do {
        let bytes = try MediaCacheReader(url: urlStr).read(offset: Int64(start), count: wanted)
        guard !bytes.isEmpty else { return -1 }
        bytes.copyBytes(to: out, count: bytes.count)
        return bytes.count
    } catch { return -1 }
}

/// Stream open: start a streaming GET from `start` offset.
/// Returns a stream ID (>0) or 0 on failure.
private func iosStreamOpen(
    _ user: UnsafeMutableRawPointer?,
    _ url: UnsafePointer<CChar>?,
    _ start: UInt64
) -> UnsafeMutableRawPointer? {
    guard let url = url else { return nil }
    let urlStr = String(cString: url)
    let streamId = CryptoNativePlugin.shared.openStream(url: urlStr, start: start)
    if streamId == 0 { return nil }
    // Encode stream ID as a raw pointer (same trick as Android JNI bridge)
    return UnsafeMutableRawPointer(bitPattern: Int(streamId))
}

/// Stream read: block until data arrives, copy into `out`.
/// Returns bytes read (>0), 0 on EOF, -1 on error.
private func iosStreamRead(
    _ user: UnsafeMutableRawPointer?,
    _ stream: UnsafeMutableRawPointer?,
    _ out: UnsafeMutablePointer<UInt8>?,
    _ cap: Int
) -> Int {
    guard let stream = stream, let out = out else { return -1 }
    let streamId = Int64(Int(bitPattern: stream))
    return CryptoNativePlugin.shared.readStream(id: streamId, buf: out,
                                                 capacity: cap)
}

/// Stream close: cancel and release the stream.
private func iosStreamClose(
    _ user: UnsafeMutableRawPointer?,
    _ stream: UnsafeMutableRawPointer?
) {
    guard let stream = stream else { return }
    let streamId = Int64(Int(bitPattern: stream))
    CryptoNativePlugin.shared.closeStream(id: streamId)
}
