import Foundation

// MARK: - Stream Buffer (thread-safe producer/consumer)

/// Thread-safe byte buffer for streaming HTTP data from URLSession delegate
/// to the synchronous C read callback.
final class StreamBuffer {
    private var data = Data()
    private var finished = false
    private var error = false
    private let condition = NSCondition()

    func append(_ chunk: Data) {
        condition.lock()
        data.append(chunk)
        condition.signal()
        condition.unlock()
    }

    func markFinished() {
        condition.lock()
        finished = true
        condition.signal()
        condition.unlock()
    }

    func markError() {
        condition.lock()
        error = true
        finished = true
        condition.signal()
        condition.unlock()
    }

    /// Blocking read: waits until data is available, EOF, or error.
    /// Returns bytes copied (>0), 0 on EOF, -1 on error.
    func read(into buf: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        condition.lock()
        while data.isEmpty && !finished {
            condition.wait()
        }
        if error {
            condition.unlock()
            return -1
        }
        if data.isEmpty && finished {
            condition.unlock()
            return 0
        }
        let count = min(data.count, capacity)
        data.copyBytes(to: buf, count: count)
        data.removeFirst(count)
        condition.unlock()
        return count
    }
}

// MARK: - Stream Delegate

/// URLSession delegate that feeds received data into a StreamBuffer.
final class StreamDelegate: NSObject, URLSessionDataDelegate {
    let buffer: StreamBuffer

    init(buffer: StreamBuffer) {
        self.buffer = buffer
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if error != nil {
            buffer.markError()
        } else {
            buffer.markFinished()
        }
    }
}

// MARK: - Stream Context

/// Holds a streaming HTTP connection: the URLSession, delegate, and buffer.
final class StreamContext {
    let session: URLSession
    let delegate: StreamDelegate
    let buffer: StreamBuffer
    let task: URLSessionDataTask

    init(session: URLSession, delegate: StreamDelegate,
         buffer: StreamBuffer, task: URLSessionDataTask) {
        self.session = session
        self.delegate = delegate
        self.buffer = buffer
        self.task = task
    }

    func cancel() {
        task.cancel()
        session.invalidateAndCancel()
        buffer.markError()
    }
}

// MARK: - CryptoNativePlugin

/// Singleton that manages the native crypto bridge lifecycle and stream registry.
final class CryptoNativePlugin {
    static let shared = CryptoNativePlugin()
    private init() {}

    private var initialized = false
    private var streams: [Int64: StreamContext] = [:]
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
        let buffer = StreamBuffer()
        let delegate = StreamDelegate(buffer: buffer)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: delegate,
                                 delegateQueue: nil)

        guard let reqUrl = URL(string: url) else { return 0 }
        var request = URLRequest(url: reqUrl)
        request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        task.resume()

        let ctx = StreamContext(session: session, delegate: delegate,
                                buffer: buffer, task: task)
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
        return ctx.buffer.read(into: buf, capacity: capacity)
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
    guard let reqUrl = URL(string: urlStr) else { return -1 }

    let semaphore = DispatchSemaphore(value: 0)
    var result: Int = -1

    var request = URLRequest(url: reqUrl)
    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
    request.timeoutInterval = 30

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard let data = data, error == nil else { return }
        let httpResp = response as? HTTPURLResponse
        let status = httpResp?.statusCode ?? 0
        guard status >= 200, status < 400 else { return }
        let count = min(data.count, outCap)
        data.copyBytes(to: out, count: count)
        result = count
    }
    task.resume()
    semaphore.wait()
    return result
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
