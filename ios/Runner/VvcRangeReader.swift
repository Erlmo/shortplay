import Foundation

/// Small decrypted range cache for the two interleaved MP4 tracks. The native
/// stream is sequential: seeking it for every AAC/VVC packet repeatedly restarts
/// range fetching. Read each block once, then demux both tracks from that block.
/// All access, including eviction, is confined to the player's I/O queue.
final class VvcRangeReader {
    private let size: Int64
    private let source: VvcSampleIndex.Read
    private let blockSize: Int64 = 64 * 1024
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []

    init(size: Int64, source: @escaping VvcSampleIndex.Read) {
        self.size = size
        self.source = source
    }

    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= size, Int64(count) <= size - offset else {
            throw VvcSampleIndex.invalid("视频读取范围无效")
        }
        var result = Data()
        result.reserveCapacity(count)
        var cursor = offset
        while result.count < count {
            let base = cursor / blockSize * blockSize
            let data: Data
            if let cached = blocks[base] {
                data = cached
                order.removeAll { $0 == base }
            } else {
                let length = Int(min(blockSize, size - base))
                data = try source(base, length)
                guard data.count == length else { throw VvcSampleIndex.invalid("视频分块读取失败") }
                blocks[base] = data
            }
            order.append(base)
            while order.count > 32 { blocks.removeValue(forKey: order.removeFirst()) }
            let start = Int(cursor - base)
            let length = min(count - result.count, data.count - start)
            result.append(data[start..<(start + length)])
            cursor += Int64(length)
        }
        return result
    }
}
