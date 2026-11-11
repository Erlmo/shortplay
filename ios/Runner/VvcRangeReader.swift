import Foundation

/// Bounded decrypted block prefixes. Fill only through the requested byte so a
/// small AAC packet cannot wait for an unrelated future video packet.
/// All access stays on the player's serial IO queue.
final class VvcRangeReader {
    private let size: Int64
    private let source: VvcSampleIndex.Read
    private let sourceReady: ((Int64, Int) throws -> Bool)?
    private let blockSize: Int64 = 64 * 1024
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []

    init(size: Int64, sourceReady: ((Int64, Int) throws -> Bool)? = nil,
         source: @escaping VvcSampleIndex.Read) {
        self.size = size
        self.sourceReady = sourceReady
        self.source = source
    }

    private func validate(offset: Int64, count: Int) throws {
        guard offset >= 0, count >= 0, offset <= size, Int64(count) <= size - offset else {
            throw VvcSampleIndex.invalid("视频读取范围无效")
        }
    }

    /// Audio prefetch yields instead of holding up video when its next packet
    /// is not buffered yet. No partial IO is started until every missing span
    /// is ready in the native stream.
    func readIfAvailable(offset: Int64, count: Int) throws -> Data? {
        try validate(offset: offset, count: count)
        var cursor = offset
        let end = offset + Int64(count)
        while cursor < end {
            let base = cursor / blockSize * blockSize
            let needed = Int(min(end - base, blockSize))
            let cached = blocks[base]?.count ?? 0
            if cached < needed, let ready = sourceReady,
               try !ready(base + Int64(cached), needed - cached) { return nil }
            cursor = base + Int64(needed)
        }
        return try read(offset: offset, count: count)
    }

    func read(offset: Int64, count: Int) throws -> Data {
        try validate(offset: offset, count: count)
        var result = Data()
        result.reserveCapacity(count)
        var cursor = offset
        while result.count < count {
            let base = cursor / blockSize * blockSize
            let start = Int(cursor - base)
            let length = min(count - result.count, Int(min(blockSize, size - base)) - start)
            let needed = start + length
            var data = blocks[base] ?? Data()
            if data.count < needed {
                let missing = needed - data.count
                let suffix = try source(base + Int64(data.count), missing)
                guard suffix.count == missing else { throw VvcSampleIndex.invalid("视频分块读取失败") }
                data.append(suffix)
                blocks[base] = data
            }
            order.removeAll { $0 == base }
            order.append(base)
            while order.count > 32 { blocks.removeValue(forKey: order.removeFirst()) }
            result.append(data[start..<(start + length)])
            cursor += Int64(length)
        }
        return result
    }
}
