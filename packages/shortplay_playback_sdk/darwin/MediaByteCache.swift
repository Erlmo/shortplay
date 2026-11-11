import Foundation
import CryptoKit
import AVFoundation

/// Shared disk format with the Dart SDK and Android adapter. It stores original
/// media bytes, never decrypted data or a replacement playback URL.
final class MediaByteCache {
    static let shared = MediaByteCache()
    static let blockSize = 32768
    let root: URL
    private let lock = NSRecursiveLock()
    private let maxBytes: Int
    private var lastTrim: TimeInterval = 0
#if os(iOS)
    private let maintenanceQueue = DispatchQueue(label: "com.shortplay.media-cache.maintenance", qos: .utility)
    private var maintenanceScheduled = false
#endif

    struct Metadata {
        let total: Int64
        let expiresAt: Double
        let etag: String?
    }

    init(root: URL? = nil, maxBytes: Int = 300 * 1024 * 1024) {
        self.maxBytes = max(0, maxBytes)
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shortplay_media_v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func key(_ url: String) -> String {
        hash(Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func object(_ url: String) -> URL { root.appendingPathComponent(Self.key(url), isDirectory: true) }
    private func block(_ url: String, _ index: Int64) -> URL {
        object(url).appendingPathComponent("blocks/\(index).blk")
    }

    func metadata(_ url: String) -> Metadata? {
        lock.lock(); defer { lock.unlock() }
        return metadataUnlocked(url)
    }
    private func metadataUnlocked(_ url: String) -> Metadata? {
        let path = object(url).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: path), data.count < 16384,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["version"] as? NSNumber)?.intValue == 1,
              let total = (json["totalLength"] as? NSNumber)?.int64Value, total > 0,
              let expiry = (json["expiresAt"] as? NSNumber)?.doubleValue,
              expiry > Date().timeIntervalSince1970 * 1000 else { return nil }
        return Metadata(total: total, expiresAt: expiry, etag: json["etag"] as? String)
    }

    /// Returns only a contiguous verified prefix; absent bytes never become EOF.
    func readPrefix(_ url: String, offset: Int64, count: Int) -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        lock.lock(); defer { lock.unlock() }
        guard let meta = metadataUnlocked(url), offset < meta.total else { return Data() }
        var cursor = offset
        var result = Data()
        let desired = Int(min(Int64(count), meta.total - offset))
        while result.count < desired {
            let index = cursor / Int64(Self.blockSize)
            let base = index * Int64(Self.blockSize)
            let expected = Int(min(Int64(Self.blockSize), meta.total - base))
            let path = block(url, index)
            guard let bytes = try? Data(contentsOf: path), bytes.count == expected + 32 else { break }
            let payload = Data(bytes.dropFirst(32))
            guard Self.hash(payload) == bytes.prefix(32) else {
                try? FileManager.default.removeItem(at: path)
                break
            }
            let start = Int(cursor - base)
            let take = min(expected - start, desired - result.count)
            result.append(payload.subdata(in: start..<(start + take)))
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
            cursor += Int64(take)
        }
        return result
    }

    func store(_ url: String, offset: Int64, data: Data, total: Int64, etag: String? = nil) {
        guard offset >= 0, total > 0, !data.isEmpty, offset <= total,
              Int64(data.count) <= total - offset else { return }
        lock.lock(); defer { lock.unlock() }
        let dir = object(url)
        let previous = metadataUnlocked(url)
        if (FileManager.default.fileExists(atPath: dir.path) && previous == nil) ||
            (previous != nil && (previous!.total != total ||
                (previous!.etag != nil && etag != nil && previous!.etag != etag))) {
            try? FileManager.default.removeItem(at: dir)
        }
        do {
            let old = metadataUnlocked(url)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("blocks"), withIntermediateDirectories: true)
            var json: [String: Any] = ["version": 1, "totalLength": total,
                "expiresAt": old?.expiresAt ?? (Date().timeIntervalSince1970 + 3600) * 1000]
            if let validator = etag ?? old?.etag { json["etag"] = validator }
            let meta = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try meta.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            let last = offset + Int64(data.count)
            var base = ((offset + Int64(Self.blockSize) - 1) / Int64(Self.blockSize)) * Int64(Self.blockSize)
            while base < last {
                let length = min(Int64(Self.blockSize), total - base)
                guard length > 0, base + length <= last else { break }
                let begin = Int(base - offset)
                let payload = data.subdata(in: begin..<(begin + Int(length)))
                var bytes = Self.hash(payload); bytes.append(payload)
                try bytes.write(to: block(url, base / Int64(Self.blockSize)), options: .atomic)
                base += Int64(Self.blockSize)
            }
            trimUnlocked()
        } catch {
            // Disk pressure cannot turn a valid network response into a failure.
        }
    }

    func prune() {
#if os(iOS)
        // Explicit pruning still waits for completion, but never holds the
        // playback cache lock while enumerating the whole directory.
        maintenanceQueue.sync { trimIOSFiles() }
#else
        lock.lock(); defer { lock.unlock() }
        trimUnlocked(force: true)
#endif
    }

    private func trimUnlocked(force: Bool = false) {
        let now = Date().timeIntervalSince1970
#if os(iOS)
        guard !maintenanceScheduled, force || now - lastTrim >= 30 else { return }
        lastTrim = now
        maintenanceScheduled = true
        maintenanceQueue.async { [weak self] in
            guard let self = self else { return }
            self.trimIOSFiles()
            self.lock.lock(); self.maintenanceScheduled = false; self.lock.unlock()
        }
#else
        guard force || now - lastTrim >= 2 else { return }
        lastTrim = now
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var entries: [(URL, Int, Date)] = []
        var total = 0
        for case let path as URL in enumerator where path.pathExtension == "blk" {
            guard let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let size = values.fileSize ?? 0
            total += size
            entries.append((path, size, values.contentModificationDate ?? .distantPast))
        }
        if total > maxBytes {
            for (path, size, _) in entries.sorted(by: { $0.2 < $1.2 }) where total > maxBytes {
                if (try? FileManager.default.removeItem(at: path)) != nil { total -= size }
            }
        }
#endif
    }

#if os(iOS)
    private func trimIOSFiles() {
        // File enumeration can take seconds on older phones. Do it off the
        // producer thread and outside the lock used by reads/writes.
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var entries: [(URL, Int, Date)] = []
        var total = 0
        for case let path as URL in enumerator where path.pathExtension == "blk" {
            guard let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let size = values.fileSize ?? 0
            total += size
            entries.append((path, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > maxBytes else { return }
        for (path, size, date) in entries.sorted(by: { $0.2 < $1.2 }) where total > maxBytes {
            lock.lock()
            var currentPath = path
            currentPath.removeAllCachedResourceValues()
            // Recheck under the write lock: don't evict a block refreshed while
            // the directory snapshot was being collected.
            if let current = try? currentPath.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               current.fileSize == size, current.contentModificationDate == date,
               (try? FileManager.default.removeItem(at: path)) != nil {
                total -= size
            }
            lock.unlock()
        }
    }
#endif
}

/// A typed transport failure is kept separate from invalid media and cancellation.
/// HTTP 4xx/5xx may move to another official candidate; malformed Range never does.
struct MediaNetworkFailure: Error {
    enum Kind { case http(Int), transport, invalid, rangeUnsupported, cancelled }
    let kind: Kind
    var partial = Data()
    var total: Int64 = 0
    var etag: String?
    init(_ kind: Kind, partial: Data = Data(), total: Int64 = 0, etag: String? = nil) {
        self.kind = kind; self.partial = partial; self.total = total; self.etag = etag
    }
    static func classify(_ error: Error) -> MediaNetworkFailure {
        if let value = error as? MediaNetworkFailure { return value }
        let code = (error as? URLError)?.code
        if code == .cancelled { return MediaNetworkFailure(.cancelled) }
        if [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(code) {
            return MediaNetworkFailure(.transport)
        }
        return MediaNetworkFailure(.invalid)
    }
    var canRetry: Bool {
        switch kind { case .transport, .http: return true; default: return false }
    }
}

/// Registry values are immutable candidate snapshots. Re-registering the exact
/// same signed primary/list keeps the current preference, not an in-flight task.
final class MediaSourceRegistry {
    static let shared = MediaSourceRegistry()
    private let lock = NSLock()
    private var sources: [String: MediaSourceContext] = [:]
    private var order: [String] = []
    static func valid(_ text: String) -> Bool {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }
    func register(primary: String, urls: [String], expiresAt: Double?) {
        guard Self.valid(primary) else { return }
        var candidates = [primary]
        for url in urls where candidates.count < 4 && Self.valid(url) && !candidates.contains(url) { candidates.append(url) }
        let now = Date().timeIntervalSince1970 * 1000
        let expiry = expiresAt.flatMap { $0.isFinite ? $0 : nil } ?? now + 3_600_000
        lock.lock(); defer { lock.unlock() }
        if expiry <= now { sources.removeValue(forKey: primary); order.removeAll { $0 == primary }; return }
        sources = sources.filter { $0.value.expiresAt > now }
        order.removeAll { sources[$0] == nil || $0 == primary }
        if let old = sources[primary], old.urls == candidates, old.expiresAt > now, old.expiresAt <= expiry {
            sources[primary] = old
        } else { sources[primary] = MediaSourceContext(primary: primary, urls: candidates, expiresAt: expiry) }
        order.append(primary)
        while order.count > 64 { sources.removeValue(forKey: order.removeFirst()) }
    }
    func context(_ primary: String) -> MediaSourceContext {
        lock.lock(); defer { lock.unlock() }
        if let value = sources[primary], value.expiresAt > Date().timeIntervalSince1970 * 1000 { return value }
        return MediaSourceContext(primary: primary, urls: [primary], expiresAt: Date().timeIntervalSince1970 * 1000 + 3_600_000)
    }
}

final class MediaSourceContext {
    let primary: String, urls: [String], expiresAt: Double
    private let lock = NSLock()
    private var index = 0
    private var anchorTotal: Int64?
    private var anchorEtag: String?
    private var prefix = Data()
    private var delivered = false
    private var origin: String?
    init(primary: String, urls: [String], expiresAt: Double) {
        self.primary = primary; self.urls = urls; self.expiresAt = expiresAt
    }
    var currentURL: String { lock.lock(); defer { lock.unlock() }; return urls[index] }
    var hasAlternates: Bool { urls.count > 1 }
    var budget: Int { max(3, urls.count) }
    func record(url: String, offset: Int64, data: Data, total: Int64, etag: String?) throws {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = anchorTotal, old != total { throw MediaNetworkFailure(.invalid) }
        anchorTotal = total
        if origin == nil { origin = url; anchorEtag = etag }
        if offset == Int64(prefix.count), prefix.count < min(32768, Int(total)) {
            prefix.append(data.prefix(min(data.count, min(32768, Int(total)) - prefix.count)))
        }
        delivered = true
    }
    /// Header and prefix validation happens before any replacement body is used.
    func validate(url: String, total: Int64, etag: String?, cancellation: MediaReadCancellation,
                  checked: inout Set<String>, cache: MediaByteCache = .shared) throws {
        lock.lock()
        let oldTotal = anchorTotal, oldEtag = anchorEtag, original = origin
        let oldPrefix = prefix, hasData = delivered
        lock.unlock()
        if let old = oldTotal, old != total { throw MediaNetworkFailure(.invalid) }
        if original == url, let old = oldEtag, let current = etag, old != current { throw MediaNetworkFailure(.invalid) }
        guard hasData, original != url else { return }
        if let old = oldEtag, !old.hasPrefix("W/"), !old.isEmpty, old == etag { return }
        guard let old = oldTotal, oldPrefix.count == min(32768, Int(old)) else { throw MediaNetworkFailure(.invalid) }
        if checked.contains(url) { return }
        if cancellation.cancelled { throw MediaNetworkFailure(.cancelled) }
        let cached = cache.readPrefix(url, offset: 0, count: oldPrefix.count)
        let bytes: Data
        if cached.count == oldPrefix.count, cache.metadata(url)?.total == old { bytes = cached }
        else {
            let probe = try MediaRangeNetwork.shared.fetch(url: url, start: 0, end: Int64(oldPrefix.count - 1), cancellation: cancellation)
            guard probe.total == old else { throw MediaNetworkFailure(.invalid) }
            bytes = probe.data
        }
        guard MediaByteCache.hash(bytes) == MediaByteCache.hash(oldPrefix) else { throw MediaNetworkFailure(.invalid) }
        checked.insert(url)
        cache.store(url, offset: 0, data: bytes, total: old, etag: nil)
    }
    func preflight(url: String, cancellation: MediaReadCancellation, checked: inout Set<String>, cache: MediaByteCache = .shared) throws {
        lock.lock(); let total = anchorTotal
        let canUseHeader = anchorEtag.map { !$0.hasPrefix("W/") && !$0.isEmpty } ?? false
        let incompletePrefix = anchorTotal.map { prefix.count < min(32768, Int($0)) } ?? true
        lock.unlock()
        if canUseHeader && incompletePrefix { return }
        if let total = total { try validate(url: url, total: total, etag: nil, cancellation: cancellation, checked: &checked, cache: cache) }
    }
    func validateHeaders(url: String, total: Int64, etag: String?, checked: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        if let old = anchorTotal, old != total { throw MediaNetworkFailure(.invalid) }
        if origin == url, let old = anchorEtag, let current = etag, old != current { throw MediaNetworkFailure(.invalid) }
        if delivered, origin != url {
            let sameStrong = anchorEtag.map { !$0.hasPrefix("W/") && !$0.isEmpty && $0 == etag } ?? false
            if !sameStrong && !checked.contains(url) { throw MediaNetworkFailure(.invalid) }
        }
    }
    func next(after url: String, failure: MediaNetworkFailure, forbidden: inout Set<String>) -> String? {
        guard failure.canRetry else { return nil }
        if case .http(let status) = failure.kind, (400...599).contains(status) { forbidden.insert(url) }
        lock.lock(); defer { lock.unlock() }
        let start = urls.firstIndex(of: url) ?? index
        let strong = anchorEtag.map { !$0.hasPrefix("W/") && !$0.isEmpty } ?? false
        let prefixReady = anchorTotal.map { prefix.count == min(32768, Int($0)) } ?? false
        if delivered && !strong && !prefixReady { return forbidden.contains(url) ? nil : url }
        for step in 1...urls.count {
            let next = (start + step) % urls.count
            if !forbidden.contains(urls[next]) { index = next; return urls[next] }
        }
        return nil
    }
    func prefer(_ url: String) { lock.lock(); if let value = urls.firstIndex(of: url) { index = value }; lock.unlock() }
}

/// Cancels only this read/stream; it never cancels another player's request.
final class MediaReadCancellation {
    private let lock = NSLock()
    private var stopped = false
    private var tasks: [ObjectIdentifier: URLSessionTask] = [:]
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func register(_ task: URLSessionTask) {
        lock.lock(); let cancel = stopped
        if !cancel { tasks[ObjectIdentifier(task)] = task }
        lock.unlock()
        if cancel { task.cancel() }
    }
    func remove(_ task: URLSessionTask) { lock.lock(); tasks.removeValue(forKey: ObjectIdentifier(task)); lock.unlock() }
    func cancel() {
        lock.lock(); stopped = true; let pending = Array(tasks.values); tasks.removeAll(); lock.unlock()
        pending.forEach { $0.cancel() }
    }
}

struct MediaHTTPRange {
    let start: Int64
    let end: Int64
    let total: Int64
    static func parse(_ value: String?) -> MediaHTTPRange? {
        guard let value = value else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let lengths = parts[1].split(separator: "/"), span = lengths.first?.split(separator: "-") ?? []
        guard lengths.count == 2, span.count == 2, let start = Int64(span[0]), let end = Int64(span[1]),
              let total = Int64(lengths[1]), start >= 0, end >= start, total > end else { return nil }
        return MediaHTTPRange(start: start, end: end, total: total)
    }
}

/// Bounded Range requests share a connection pool. Headers are validated before
/// accepting any body, so an origin ignoring Range cannot allocate a whole movie.
private final class MediaRangeNetwork: NSObject, URLSessionDataDelegate {
    static let shared = MediaRangeNetwork()
    struct Response { let data: Data; let total: Int64; let etag: String? }
    private final class Pending {
        let start: Int64, end: Int64
        let finished = DispatchSemaphore(value: 0)
        var expected: Int64 = 0, total: Int64 = 0
        var etag: String?, data = Data(), error: Error?
        var verified = false
        init(start: Int64, end: Int64) { self.start = start; self.end = end }
    }
    private let lock = NSLock()
    private var requests: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private func pending(_ task: URLSessionTask) -> Pending? {
        lock.lock(); defer { lock.unlock() }; return requests[task.taskIdentifier]
    }
    func fetch(url: String, start: Int64, end: Int64,
               cancellation: MediaReadCancellation) throws -> Response {
        guard let source = URL(string: url), ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
              start >= 0, end >= start else { throw URLError(.badURL) }
        if cancellation.cancelled { throw URLError(.cancelled) }
        var request = URLRequest(url: source)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let state = Pending(start: start, end: end)
        let task = session.dataTask(with: request)
        lock.lock(); requests[task.taskIdentifier] = state; lock.unlock()
        cancellation.register(task); task.resume()
        state.finished.wait()
        cancellation.remove(task)
        if cancellation.cancelled { throw URLError(.cancelled) }
        if let error = state.error {
            var failure = MediaNetworkFailure.classify(error)
            if state.verified, case .transport = failure.kind {
                failure.partial = state.data; failure.total = state.total; failure.etag = state.etag
            }
            throw failure
        }
        return Response(data: state.data, total: state.total, etag: state.etag)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = pending(dataTask), let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else {
            state.error = MediaNetworkFailure(.invalid); completionHandler(.cancel); return
        }
        if (400...599).contains(http.statusCode) {
            state.error = MediaNetworkFailure(.http(http.statusCode)); completionHandler(.cancel); return
        }
        if http.statusCode == 206, let range = MediaHTTPRange.parse(http.value(forHTTPHeaderField: "Content-Range")),
           range.start == state.start, range.end <= min(state.end, range.total - 1) {
            state.total = range.total; state.expected = range.end - range.start + 1
        } else if http.statusCode == 200, state.start == 0,
                  response.expectedContentLength > 0, response.expectedContentLength <= state.end + 1 {
            state.total = response.expectedContentLength; state.expected = state.total
        } else {
            state.error = MediaNetworkFailure(http.statusCode == 200 ? .rangeUnsupported : .invalid); completionHandler(.cancel); return
        }
        if response.expectedContentLength >= 0 && response.expectedContentLength != state.expected {
            state.error = MediaNetworkFailure(.invalid); completionHandler(.cancel); return
        }
        state.verified = true
        state.etag = http.value(forHTTPHeaderField: "ETag")
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = pending(dataTask) else { return }
        if Int64(state.data.count) + Int64(data.count) > state.expected {
            state.error = MediaNetworkFailure(.invalid); dataTask.cancel(); return
        }
        state.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let state = requests.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let state = state else { return }
        if state.error == nil { state.error = error }
        if state.error == nil && (state.total <= 0 || Int64(state.data.count) != state.expected) {
            state.error = URLError(.networkConnectionLost)
        }
        state.finished.signal()
    }
}

/// Synchronous range reader for native IO threads. No caller may run it on main.
/// Reads are bounded, checked against Content-Range and persisted only as whole
/// checksum-protected blocks. A smaller successful response is valid only at EOF.
final class MediaCacheReader {
    let url: String
    let cancellation: MediaReadCancellation
    private let cache: MediaByteCache
    private let source: MediaSourceContext
    var metadata: MediaByteCache.Metadata? { cache.metadata(source.currentURL) }
    init(url: String, cancellation: MediaReadCancellation = MediaReadCancellation(), cache: MediaByteCache = .shared) {
        self.url = url; self.cancellation = cancellation; self.cache = cache
        self.source = MediaSourceRegistry.shared.context(url)
    }
    func read(offset: Int64, count: Int) throws -> Data {
        guard !Thread.isMainThread else { throw MediaNetworkFailure(.invalid) }
        if cancellation.cancelled { throw MediaNetworkFailure(.cancelled) }
        guard offset >= 0, count > 0, Int64(count) <= Int64.max - offset else { return Data() }
        var candidate = source.currentURL
        var checked = Set<String>()
        var result = cache.readPrefix(candidate, offset: offset, count: count)
        if !result.isEmpty, let meta = cache.metadata(candidate) {
            try source.validate(url: candidate, total: meta.total, etag: meta.etag, cancellation: cancellation, checked: &checked, cache: cache)
            try source.record(url: candidate, offset: offset, data: result, total: meta.total, etag: meta.etag)
        }
        if result.count == count || metadata?.total == offset + Int64(result.count) { return result }
        var forbidden = Set<String>(), failures = 0
        var segment = result, segmentStart = offset
        while result.count < count {
            if cancellation.cancelled { throw MediaNetworkFailure(.cancelled) }
            let start = offset + Int64(result.count), end = offset + Int64(count) - 1
            do {
                let response = try MediaRangeNetwork.shared.fetch(url: candidate, start: start, end: end, cancellation: cancellation)
                try source.validate(url: candidate, total: response.total, etag: response.etag, cancellation: cancellation, checked: &checked, cache: cache)
                guard !response.data.isEmpty else { throw MediaNetworkFailure(.transport) }
                if cancellation.cancelled { throw MediaNetworkFailure(.cancelled) }
                try source.record(url: candidate, offset: start, data: response.data, total: response.total, etag: response.etag)
                segment.append(response.data)
                cache.store(candidate, offset: segmentStart, data: segment, total: response.total, etag: response.etag)
                result.append(response.data); source.prefer(candidate)
                if offset + Int64(result.count) >= response.total { return result }
                // A valid bounded 206 made progress; it is not a failed retry.
            } catch {
                if cancellation.cancelled { throw MediaNetworkFailure(.cancelled) }
                let failure = MediaNetworkFailure.classify(error)
                if !failure.partial.isEmpty, failure.total > 0 {
                    try source.validate(url: candidate, total: failure.total, etag: failure.etag, cancellation: cancellation, checked: &checked, cache: cache)
                    try source.record(url: candidate, offset: start, data: failure.partial, total: failure.total, etag: failure.etag)
                    segment.append(failure.partial)
                    cache.store(candidate, offset: segmentStart, data: segment, total: failure.total, etag: failure.etag)
                    result.append(failure.partial)
                }
                failures += 1
                guard failure.canRetry, failures < source.budget,
                      let next = source.next(after: candidate, failure: failure, forbidden: &forbidden) else { throw failure }
                if next != candidate { segment = Data(); segmentStart = offset + Int64(result.count) }
                candidate = next
            }
        }
        if cancellation.cancelled { throw MediaNetworkFailure(.cancelled) }
        return result
    }
}

/// AVPlayer's plain HTTP path shares raw SDK blocks, without waiting for a
/// complete download or relaying media through localhost.
final class MediaCacheResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let source: String
    private let queue: DispatchQueue
    private var active: [ObjectIdentifier: MediaReadCancellation] = [:]
    private var stopped = false
    private let parkCondition = NSCondition()
    private var parked = false
    private var parkStopped = false
    func setActive(_ active: Bool) {
        parkCondition.lock(); parked = !active; parkCondition.broadcast(); parkCondition.unlock()
    }
    private func waitWhileParked(_ token: MediaReadCancellation) throws {
        parkCondition.lock(); defer { parkCondition.unlock() }
        while parked && !parkStopped && !token.cancelled {
            _ = parkCondition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        if parkStopped || token.cancelled { throw URLError(.cancelled) }
    }
    init(source: String, queue: DispatchQueue) { self.source = source; self.queue = queue }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if stopped { return false }
        let token = MediaReadCancellation(), id = ObjectIdentifier(request)
        active[id] = token
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try waitWhileParked(token)
                let reader = MediaCacheReader(url: source, cancellation: token)
                var meta = reader.metadata
                if meta == nil {
                    _ = try reader.read(offset: 0, count: MediaByteCache.blockSize)
                    meta = reader.metadata
                }
                guard let metadata = meta else { throw URLError(.badServerResponse) }
                queue.sync {
                    if !token.cancelled, let information = request.contentInformationRequest {
                        information.contentLength = metadata.total
                        information.contentType = AVFileType.mp4.rawValue
                        information.isByteRangeAccessSupported = true
                    }
                }
                if let data = request.dataRequest {
                    var offset = max(data.requestedOffset, data.currentOffset)
                    let requestedEnd = data.requestsAllDataToEndOfResource ? metadata.total : data.requestedOffset + Int64(data.requestedLength)
                    let end = min(metadata.total, requestedEnd)
                    while offset < end && !token.cancelled {
                        try waitWhileParked(token)
                        let bytes = try reader.read(offset: offset, count: Int(min(256 * 1024, end - offset)))
                        guard !bytes.isEmpty else { throw URLError(.networkConnectionLost) }
                        queue.sync { if !token.cancelled { data.respond(with: bytes) } }
                        offset += Int64(bytes.count)
                    }
                }
                queue.async { [self] in
                    active.removeValue(forKey: id)
                    if !token.cancelled { request.finishLoading() }
                }
            } catch {
                queue.async { [self] in
                    active.removeValue(forKey: id)
                    if !token.cancelled { request.finishLoading(with: error) }
                }
            }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        active.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
    func invalidate() {
        // Called on the main thread by playback disposal; do not synchronously
        // wait for the loader queue, which may be posting a response back.
        parkCondition.lock(); parkStopped = true; parkCondition.broadcast(); parkCondition.unlock()
        queue.async { [self] in
            stopped = true
            active.values.forEach { $0.cancel() }
            active.removeAll()
        }
    }
}

/// Continuous CDN tail with a bounded producer/consumer buffer. The network is
/// opened only after all contiguous disk blocks have been consumed.
private final class MediaNetworkTail: NSObject, URLSessionDataDelegate {
    private let condition = NSCondition()
    private var bytes = Data(), finished = false
    private var failure: MediaNetworkFailure?
    private var delivered: Int64 = 0, expected: Int64 = -1
    private(set) var total: Int64 = 0
    private(set) var etag: String?
    private let offset: Int64
    private let cancellation: MediaReadCancellation
    private let source: MediaSourceContext
    private let checked: Set<String>
    let url: String
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private let capacity = 1024 * 1024
    var lastError: MediaNetworkFailure { condition.lock(); defer { condition.unlock() }; return failure ?? MediaNetworkFailure(.transport) }
    init(url: String, offset: Int64, cancellation: MediaReadCancellation,
         source: MediaSourceContext, checked: Set<String>) throws {
        guard let sourceURL = URL(string: url), MediaSourceRegistry.valid(url) else { throw MediaNetworkFailure(.invalid) }
        self.url = url; self.offset = offset; self.cancellation = cancellation; self.source = source; self.checked = checked
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: sourceURL)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        task = session.dataTask(with: request); cancellation.register(task)
        if cancellation.cancelled { cancel() } else { task.resume() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { fail(MediaNetworkFailure(.invalid)); completionHandler(.cancel); return }
        if (400...599).contains(http.statusCode) { fail(MediaNetworkFailure(.http(http.statusCode))); completionHandler(.cancel); return }
        let coding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard coding == nil || coding == "identity" else { fail(MediaNetworkFailure(.invalid)); completionHandler(.cancel); return }
        if http.statusCode == 206, let range = MediaHTTPRange.parse(http.value(forHTTPHeaderField: "Content-Range")), range.start == offset {
            total = range.total; expected = range.end - range.start + 1
        } else if http.statusCode == 200, offset == 0, response.expectedContentLength > 0 {
            total = response.expectedContentLength; expected = total
        } else { fail(MediaNetworkFailure(http.statusCode == 200 ? .rangeUnsupported : .invalid)); completionHandler(.cancel); return }
        if response.expectedContentLength >= 0 && response.expectedContentLength != expected {
            fail(MediaNetworkFailure(.invalid)); completionHandler(.cancel); return
        }
        etag = http.value(forHTTPHeaderField: "ETag")
        do { try source.validateHeaders(url: url, total: total, etag: etag, checked: checked) }
        catch { fail(MediaNetworkFailure.classify(error)); completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard !finished else { return }
        if expected < 0 || delivered + Int64(data.count) > expected {
            failure = MediaNetworkFailure(.invalid); finished = true; bytes.removeAll(); condition.broadcast(); task.cancel(); return
        }
        delivered += Int64(data.count)
        var cursor = 0
        while cursor < data.count && !finished {
            while bytes.count >= capacity && !finished { condition.wait() }
            guard !finished else { return }
            let take = min(capacity - bytes.count, data.count - cursor)
            bytes.append(data.subdata(in: cursor..<(cursor + take))); cursor += take; condition.broadcast()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        if failure == nil {
            if let error = error { failure = MediaNetworkFailure.classify(error) }
            else if expected < 0 || delivered != expected { failure = MediaNetworkFailure(.transport) }
        }
        finished = true; condition.broadcast(); condition.unlock(); cancellation.remove(task)
    }
    private func fail(_ error: MediaNetworkFailure) {
        condition.lock(); failure = error; finished = true; condition.broadcast(); condition.unlock()
    }
    func read(into output: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        while bytes.isEmpty && !finished { condition.wait() }
        // Validated bytes received before a transport interruption can still be
        // delivered. The next call resumes at the actual consumer offset.
        if bytes.isEmpty, failure != nil { return -1 }
        let take = min(count, bytes.count)
        guard take > 0 else { return 0 }
        bytes.copyBytes(to: output, count: take); bytes.removeFirst(take); condition.broadcast(); return take
    }
    func cancel() {
        condition.lock(); failure = MediaNetworkFailure(.cancelled); finished = true; bytes.removeAll(); condition.broadcast(); condition.unlock()
        task?.cancel(); session?.invalidateAndCancel()
    }
    deinit { session?.invalidateAndCancel() }
}

final class MediaCachedStream {
    private let source: MediaSourceContext
    private let cache: MediaByteCache
    private let cancellation = MediaReadCancellation()
    private let lock = NSLock()
    private var tail: MediaNetworkTail?
    private var offset: Int64
    private var pending = Data(), pendingStart: Int64 = 0
    private var pendingURL: String?
    private var forbidden = Set<String>(), checked = Set<String>()
    init(url: String, start: Int64, cache: MediaByteCache = .shared) {
        source = MediaSourceRegistry.shared.context(url); offset = start; self.cache = cache
    }
    func read(into output: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var failures = 0
        var candidate = source.currentURL
        while failures < source.budget {
            if cancellation.cancelled { return -1 }
            lock.lock(); let existing = tail; lock.unlock()
            if existing == nil {
                let cached = cache.readPrefix(candidate, offset: offset, count: count)
                if !cached.isEmpty, let meta = cache.metadata(candidate) {
                    do {
                        try source.validate(url: candidate, total: meta.total, etag: meta.etag, cancellation: cancellation, checked: &checked, cache: cache)
                        try source.record(url: candidate, offset: offset, data: cached, total: meta.total, etag: meta.etag)
                    } catch { return -1 }
                    cached.copyBytes(to: output, count: cached.count); offset += Int64(cached.count); return cached.count
                }
                if let total = cache.metadata(candidate)?.total, offset >= total { return 0 }
            }
            do {
                let stream: MediaNetworkTail
                if let existing = existing { stream = existing; candidate = stream.url }
                else {
                    try source.preflight(url: candidate, cancellation: cancellation, checked: &checked, cache: cache)
                    stream = try MediaNetworkTail(url: candidate, offset: offset, cancellation: cancellation, source: source, checked: checked)
                    lock.lock(); tail = stream; lock.unlock()
                    if cancellation.cancelled { stream.cancel(); return -1 }
                }
                let n = stream.read(into: output, count: count)
                if n > 0 {
                    if cancellation.cancelled { return -1 }
                    let bytes = Data(bytes: output, count: n)
                    try source.record(url: candidate, offset: offset, data: bytes, total: stream.total, etag: stream.etag)
                    appendForCache(bytes, url: candidate, total: stream.total, etag: stream.etag)
                    source.prefer(candidate); offset += Int64(n); forbidden.removeAll(); return n
                }
                if n == 0 {
                    if stream.total <= offset { return 0 }
                    stream.cancel(); lock.lock(); tail = nil; lock.unlock()
                    continue // Valid bounded 206, not a failure or media EOF.
                }
                throw stream.lastError
            } catch {
                if cancellation.cancelled { return -1 }
                let failure = MediaNetworkFailure.classify(error)
                lock.lock(); let failed = tail; tail = nil; lock.unlock(); failed?.cancel()
                failures += 1
                guard failure.canRetry, failures < source.budget,
                      let next = source.next(after: candidate, failure: failure, forbidden: &forbidden) else { return -1 }
                if next != candidate { pending.removeAll(); pendingURL = nil }
                candidate = next
            }
        }
        return -1
    }
    private func appendForCache(_ data: Data, url: String, total: Int64, etag: String?) {
        guard total > 0 else { return }
        if pendingURL != url { pending.removeAll(); pendingURL = url }
        var bytes = data
        if pending.isEmpty {
            let aligned = ((offset + Int64(MediaByteCache.blockSize) - 1) / Int64(MediaByteCache.blockSize)) * Int64(MediaByteCache.blockSize)
            let skip = Int(min(Int64(bytes.count), aligned - offset)); bytes.removeFirst(skip); pendingStart = offset + Int64(skip)
        }
        pending.append(bytes)
        while !pending.isEmpty {
            let wanted = Int(min(Int64(MediaByteCache.blockSize), total - pendingStart))
            guard wanted > 0, pending.count >= wanted else { break }
            let block = Data(pending.prefix(wanted))
            cache.store(url, offset: pendingStart, data: block, total: total, etag: etag)
            pending.removeFirst(wanted); pendingStart += Int64(wanted)
        }
    }
    func cancel() { cancellation.cancel(); lock.lock(); let stream = tail; tail = nil; lock.unlock(); stream?.cancel() }
    deinit { cancel() }
}
