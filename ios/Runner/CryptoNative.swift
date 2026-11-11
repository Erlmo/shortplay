import Foundation

// MARK: - CryptoNativePlugin

/// Singleton that manages the native crypto bridge lifecycle and stream registry.
final class CryptoNativePlugin {
    static let shared = CryptoNativePlugin()
    private init() {}

    private var initialized = false
    private var streams: [Int64: IOSCryptoReadStream] = [:]
    private var startupStreams: [String: IOSCryptoStartupStream] = [:]
    private var startupOrder: [String] = []
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
        var retired: IOSCryptoStartupStream?
        lock.lock()
        let startup: IOSCryptoStartupStream
        if let existing = startupStreams[cdnUrl] { startup = existing }
        else {
            if startupOrder.count >= 8 {
                retired = startupStreams.removeValue(forKey: startupOrder.removeFirst())
            }
            startup = IOSCryptoStartupStream(url: cdnUrl)
            startupStreams[cdnUrl] = startup
            startupOrder.append(cdnUrl)
            // Navigation may abandon a prewarm before any native handle exists.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self, weak startup] in
                guard let self = self, let startup = startup else { return }
                self.discardStartup(cdnUrl, matching: startup)
            }
        }
        lock.unlock()
        retired?.cancel()
        let status = sp_prewarm(cdnUrl, keyHex)
        if status != 0 { discardStartup(cdnUrl, matching: startup) }
        return status
    }

    private func discardStartup(_ url: String, matching startup: IOSCryptoStartupStream) {
        lock.lock()
        let removed = startupStreams[url] === startup
        if removed {
            startupStreams.removeValue(forKey: url)
            startupOrder.removeAll { $0 == url }
        }
        lock.unlock()
        if removed { startup.cancel() }
    }

    fileprivate func startupBytes(url: String, start: UInt64, count: Int) throws -> Data? {
        lock.lock(); let startup = startupStreams[url]; lock.unlock()
        return try startup?.bytes(start: start, count: count)
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
        lock.lock()
        let startup = startupStreams.removeValue(forKey: url)
        startupOrder.removeAll { $0 == url }
        lock.unlock()
        let ctx: IOSCryptoReadStream
        if let handedOff = startup?.handoff(start: start) { ctx = handedOff }
        else {
            startup?.cancel()
            ctx = IOSCryptoReadStream(tail: MediaCachedStream(url: url, start: Int64(start)))
        }
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
        if let bytes = try CryptoNativePlugin.shared.startupBytes(url: urlStr, start: start, count: wanted) {
            guard !bytes.isEmpty else { return -1 }
            bytes.copyBytes(to: out, count: bytes.count)
            return bytes.count
        }
        let reader = MediaCacheReader(url: urlStr)
        let relative = Int(start % UInt64(MediaByteCache.blockSize))
        let bytes: Data
        if start == 0, wanted <= MediaByteCache.blockSize {
            // Coalesce the box scan, moov and the existing 128 KiB media seed
            // into one bounded prefix read. Later native requests consume the
            // same verified raw blocks; the seed size is not reduced.
            let prefix = try reader.read(offset: 0, count: 256 * 1024)
            guard wanted <= prefix.count else { return -1 }
            bytes = prefix.subdata(in: 0..<wanted)
        } else if wanted < MediaByteCache.blockSize, relative + wanted <= MediaByteCache.blockSize {
            // Larger/non-frontloaded headers retain the aligned-block fallback.
            let block = try reader.read(offset: Int64(start) - Int64(relative), count: MediaByteCache.blockSize)
            guard relative + wanted <= block.count else { return -1 }
            bytes = block.subdata(in: relative..<(relative + wanted))
        } else {
            bytes = try reader.read(offset: Int64(start), count: wanted)
        }
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


/// A foreground prewarm and its first native producer share one validated HTTP
/// tail. Only a bounded raw prefix is retained; decryption still belongs to C.
private final class IOSCryptoStartupStream {
    private let tail: MediaCachedStream
    private let lock = NSLock()
    private var prefix = Data()
    private var exhausted = false
    private var failed = false
    private let limit = 1024 * 1024

    init(url: String) { tail = MediaCachedStream(url: url, start: 0) }

    func bytes(start: UInt64, count: Int) throws -> Data? {
        guard count > 0, start <= UInt64(limit), count <= limit - Int(start) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let end = Int(start) + count
        // Preserve the media seed and allow the usual moov to share one GET.
        let target = min(limit, max(256 * 1024, ((end + 32767) / 32768) * 32768))
        while prefix.count < target && !exhausted {
            let length = min(64 * 1024, target - prefix.count)
            var data = Data(count: length)
            let n = data.withUnsafeMutableBytes { raw in
                tail.read(into: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: length)
            }
            guard n >= 0 else { failed = true; throw MediaNetworkFailure(.transport) }
            if n == 0 { exhausted = true; break }
            prefix.append(data.prefix(n))
        }
        guard start < UInt64(prefix.count) else { return Data() }
        return prefix.subdata(in: Int(start)..<min(end, prefix.count))
    }

    func handoff(start: UInt64) -> IOSCryptoReadStream? {
        lock.lock(); defer { lock.unlock() }
        // A remote moov or a seek outside this prefix uses the existing fallback.
        guard !failed, start <= UInt64(prefix.count) else { return nil }
        return IOSCryptoReadStream(tail: tail, prefix: prefix, cursor: Int(start))
    }
    func cancel() { tail.cancel() }
}

/// The producer replays any prefetched suffix, then continues the exact same
/// connection at the next byte. Closing must interrupt a blocked tail read.
private final class IOSCryptoReadStream {
    private let tail: MediaCachedStream
    private let lock = NSLock()
    private var prefix: Data
    private var cursor: Int
    private var cancelled = false
    init(tail: MediaCachedStream, prefix: Data = Data(), cursor: Int = 0) {
        self.tail = tail; self.prefix = prefix; self.cursor = cursor
    }
    func read(into output: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        lock.lock()
        guard !cancelled else { lock.unlock(); return -1 }
        let take = min(count, prefix.count - cursor)
        if take > 0 {
            prefix.withUnsafeBytes { raw in
                output.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: cursor), count: take)
            }
            cursor += take
            if cursor == prefix.count { prefix = Data(); cursor = 0 }
            lock.unlock(); return take
        }
        lock.unlock()
        return tail.read(into: output, count: count)
    }
    func cancel() {
        lock.lock(); cancelled = true; prefix = Data(); cursor = 0; lock.unlock()
        tail.cancel()
    }
}
