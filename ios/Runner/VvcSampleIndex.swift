import Foundation

/// MP4 metadata only. The caller supplies decrypted range reads on one serial queue.
/// Samples retain the original decoding order; CTS and edit lists determine display time.
struct VvcSampleIndex {
    struct Sample {
        let offset: Int64
        let size: Int
        let presentationTimeUs: Int64
        let sync: Bool
        let durationUs: Int64
    }

    struct AudioTrack {
        let samples: [Sample]
        let magicCookie: Data
    }

    let audio: AudioTrack?
    let configuration: Data
    let samples: [Sample]
    let width: Int
    let height: Int

    typealias Read = (Int64, Int) throws -> Data

    static func invalid(_ message: String) -> NSError {
        NSError(domain: "ShortplayVvc", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func load(size: Int64, read: Read) throws -> VvcSampleIndex? {
        var offset: Int64 = 0
        while offset <= size - 8 {
            let header = try read(offset, Int(min(16, size - offset)))
            let tag = try header.tag(4)
            var length = Int64(try header.u32(0))
            var headerSize = 8
            if length == 1 {
                let value = try header.u64(8)
                guard value <= UInt64(Int64.max) else { throw invalid("MP4 数据长度异常") }
                length = Int64(value)
                headerSize = 16
            } else if length == 0 {
                length = size - offset
            }
            guard length >= headerSize, length <= size - offset else { return nil }
            if tag == "moov" {
                guard length <= 32 * 1024 * 1024 else { throw invalid("MP4 索引过大") }
                return try parse(read(offset, Int(length)), headerSize: headerSize)
            }
            offset += length
        }
        return nil
    }

    private struct Box {
        let tag: String
        let start: Int
        let end: Int
        let header: Int
        var payload: Int { start + header }
    }

    private static func boxes(_ data: Data, _ start: Int, _ end: Int) throws -> [Box] {
        var result: [Box] = []
        var at = start
        while at <= end - 8 {
            let small = try data.u32(at)
            let header = small == 1 ? 16 : 8
            let size64 = small == 1 ? try data.u64(at + 8) : UInt64(small)
            let size = size64 == 0 ? end - at : Int(min(size64, UInt64(Int.max)))
            guard size >= header, size <= end - at else { throw invalid("MP4 索引不完整") }
            result.append(Box(tag: try data.tag(at + 4), start: at, end: at + size, header: header))
            at += size
        }
        return result
    }

    private static func parse(_ data: Data, headerSize: Int) throws -> VvcSampleIndex? {
        let top = try boxes(data, headerSize, data.count)
        for track in top where track.tag == "trak" {
            let children = try boxes(data, track.payload, track.end)
            guard let mdia = children.first(where: { $0.tag == "mdia" }) else { continue }
            let media = try boxes(data, mdia.payload, mdia.end)
            guard let handler = media.first(where: { $0.tag == "hdlr" }),
                  try data.tag(handler.payload + 8) == "vide",
                  let mdhd = media.first(where: { $0.tag == "mdhd" }),
                  let minf = media.first(where: { $0.tag == "minf" }),
                  let stbl = try boxes(data, minf.payload, minf.end).first(where: { $0.tag == "stbl" }) else { continue }
            let table = try boxes(data, stbl.payload, stbl.end)
            func required(_ name: String) throws -> Box {
                guard let box = table.first(where: { $0.tag == name }) else { throw invalid("缺少 MP4 索引：\(name)") }
                return box
            }
            let stsd = try required("stsd")
            let entries = try boxes(data, stsd.payload + 8, stsd.end)
            guard let entry = entries.first else { continue }
            let extensions = try boxes(data, entry.start + 86, entry.end)
            var format = entry.tag
            if format == "encv", let sinf = extensions.first(where: { $0.tag == "sinf" }),
               let frma = try boxes(data, sinf.payload, sinf.end).first(where: { $0.tag == "frma" }) {
                format = try data.tag(frma.payload)
            }
            guard format == "bvc2" else { return nil }
            guard entries.count == 1, let config = extensions.first(where: { $0.tag == "bv2C" || $0.tag == "bvcC" }) else {
                throw invalid("不支持该 BVC2 配置")
            }
            let width = Int(try data.u16(entry.start + 32))
            let height = Int(try data.u16(entry.start + 34))
            guard width > 0, height > 0 else { throw invalid("BVC2 视频尺寸异常") }
            let result = try samples(data: data, mdhd: mdhd, children: children, table: table)
            var at = config.payload + 18
            let arrayCount = Int(try data.u8(at)); at += 1
            var configuration = Data()
            for _ in 0..<arrayCount {
                at += 1
                let n = Int(try data.u16(at)); at += 2
                for _ in 0..<n {
                    let length = Int(try data.u16(at)); at += 2
                    guard length > 0, at <= config.end - length else { throw invalid("BVC2 参数集不完整") }
                    configuration.append(contentsOf: [0, 0, 0, 1]); configuration.append(data[at..<(at + length)]); at += length
                }
            }
            guard at == config.end, !configuration.isEmpty else { throw invalid("BVC2 参数集异常") }
            return VvcSampleIndex(audio: try audioTrack(data: data, tracks: top), configuration: configuration,
                                  samples: result, width: width, height: height)
        }
        return nil
    }

    private static func samples(data: Data, mdhd: Box, children: [Box], table: [Box]) throws -> [Sample] {
        func required(_ name: String) throws -> Box {
            guard let box = table.first(where: { $0.tag == name }) else { throw invalid("缺少 MP4 索引：\(name)") }
            return box
        }
        let timescale = Int64(try data.u32(mdhd.payload + (try data.u8(mdhd.payload) == 1 ? 20 : 12)))
        guard timescale > 0 else { throw invalid("MP4 时间基无效") }
        var editTime: Int64 = 0
        if let edts = children.first(where: { $0.tag == "edts" }),
           let elst = try boxes(data, edts.payload, edts.end).first(where: { $0.tag == "elst" }),
           try data.u32(elst.payload + 4) > 0 {
            let version = try data.u8(elst.payload)
            editTime = version == 1 ? Int64(bitPattern: try data.u64(elst.payload + 16)) : Int64(Int32(bitPattern: try data.u32(elst.payload + 12)))
            guard editTime >= 0 else { throw invalid("暂不支持带空白剪辑的 BVC2 视频") }
        }
        let stsz = try required("stsz")
        let uniform = Int(try data.u32(stsz.payload + 4))
        let count = Int(try data.u32(stsz.payload + 8))
        guard count > 0, count <= 500_000 else { throw invalid("MP4 样本数量异常") }
        var sizes = [Int]()
        for i in 0..<count {
            let size = uniform > 0 ? uniform : Int(try data.u32(stsz.payload + 12 + 4 * i))
            guard size > 0, size <= 8 * 1024 * 1024 else { throw invalid("BVC2 视频包大小异常") }
            sizes.append(size)
        }
        let stts = try required("stts")
        var durations = [Int64]()
        for row in 0..<Int(try data.u32(stts.payload + 4)) {
            let n = Int(try data.u32(stts.payload + 8 + row * 8))
            let delta = Int64(try data.u32(stts.payload + 12 + row * 8))
            guard n <= count - durations.count else { throw invalid("MP4 时间索引异常") }
            durations.append(contentsOf: repeatElement(delta, count: n))
        }
        guard durations.count == count else { throw invalid("MP4 时间索引缺失") }
        var compositions = [Int64](repeating: 0, count: count)
        if let ctts = table.first(where: { $0.tag == "ctts" }) {
            var i = 0
            for row in 0..<Int(try data.u32(ctts.payload + 4)) {
                let n = Int(try data.u32(ctts.payload + 8 + row * 8))
                let raw = try data.u32(ctts.payload + 12 + row * 8)
                let delta = try data.u8(ctts.payload) == 1 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
                guard n <= count - i else { throw invalid("MP4 显示时间异常") }
                for j in i..<(i + n) { compositions[j] = delta }
                i += n
            }
            guard i == count else { throw invalid("MP4 显示时间缺失") }
        }
        var sync = Set<Int>()
        if let stss = table.first(where: { $0.tag == "stss" }) {
            for row in 0..<Int(try data.u32(stss.payload + 4)) {
                sync.insert(Int(try data.u32(stss.payload + 8 + 4 * row)) - 1)
            }
        } else { sync = Set(0..<count) }
        let stsc = try required("stsc")
        var mappings = [(chunk: Int, samples: Int)]()
        for row in 0..<Int(try data.u32(stsc.payload + 4)) {
            let at = stsc.payload + 8 + row * 12
            guard try data.u32(at + 8) == 1 else { throw invalid("不支持多配置的 BVC2 视频") }
            let first = Int(try data.u32(at)), n = Int(try data.u32(at + 4))
            guard n > 0, n <= count, first > (mappings.last?.chunk ?? 0) else { throw invalid("MP4 分块映射异常") }
            mappings.append((first, n))
        }
        guard mappings.first?.chunk == 1 else { throw invalid("MP4 分块映射缺失") }
        guard let chunks = table.first(where: { $0.tag == "stco" || $0.tag == "co64" }) else { throw invalid("MP4 分块索引缺失") }
        let chunkCount = Int(try data.u32(chunks.payload + 4))
        guard chunkCount <= count else { throw invalid("MP4 分块数量异常") }
        var result = [Sample](), mapping = 0, dts: Int64 = 0
        for chunk in 0..<chunkCount {
            while mapping + 1 < mappings.count, chunk + 1 >= mappings[mapping + 1].chunk { mapping += 1 }
            let base = chunks.payload + 8 + chunk * (chunks.tag == "co64" ? 8 : 4)
            let rawOffset = chunks.tag == "co64" ? try data.u64(base) : UInt64(try data.u32(base))
            guard rawOffset <= UInt64(Int64.max) else { throw invalid("MP4 偏移异常") }
            var offset = Int64(rawOffset)
            for _ in 0..<mappings[mapping].samples {
                let i = result.count
                guard i < count else { throw invalid("MP4 样本索引异常") }
                let pts = (dts + compositions[i] - editTime) * 1_000_000 / timescale
                result.append(Sample(offset: offset, size: sizes[i], presentationTimeUs: pts,
                             sync: sync.contains(i), durationUs: durations[i] * 1_000_000 / timescale))
                offset += Int64(sizes[i]); dts += durations[i]
            }
        }
        guard result.count == count else { throw invalid("MP4 样本索引缺失") }
        return result
    }

    private static func audioTrack(data: Data, tracks: [Box]) throws -> AudioTrack? {
        for track in tracks where track.tag == "trak" {
            let children = try boxes(data, track.payload, track.end)
            guard let mdia = children.first(where: { $0.tag == "mdia" }) else { continue }
            let media = try boxes(data, mdia.payload, mdia.end)
            guard let handler = media.first(where: { $0.tag == "hdlr" }),
                  try data.tag(handler.payload + 8) == "soun",
                  let mdhd = media.first(where: { $0.tag == "mdhd" }),
                  let minf = media.first(where: { $0.tag == "minf" }),
                  let stbl = try boxes(data, minf.payload, minf.end).first(where: { $0.tag == "stbl" }) else { continue }
            let table = try boxes(data, stbl.payload, stbl.end)
            guard let stsd = table.first(where: { $0.tag == "stsd" }),
                  let entry = try boxes(data, stsd.payload + 8, stsd.end).first,
                  entry.tag == "mp4a", try data.u16(entry.start + 16) == 0,
                  let esds = try boxes(data, entry.start + 36, entry.end).first(where: { $0.tag == "esds" }) else {
                throw invalid("BVC2 音轨暂仅支持 AAC")
            }
            func descriptor(_ at: Int, tag: UInt8) throws -> (start: Int, end: Int) {
                guard try data.u8(at) == tag else { throw invalid("AAC 参数描述异常") }
                var cursor = at + 1, length = 0
                for i in 0..<4 {
                    let value = try data.u8(cursor); cursor += 1
                    length = length * 128 + Int(value & 0x7f)
                    if value & 0x80 == 0 {
                        guard length <= esds.end - cursor else { throw invalid("AAC 参数不完整") }
                        return (cursor, cursor + length)
                    }
                    if i == 3 { throw invalid("AAC 参数长度异常") }
                }
                throw invalid("AAC 参数缺失")
            }
            let es = try descriptor(esds.payload + 4, tag: 3)
            let flags = try data.u8(es.start + 2)
            var cursor = es.start + 3
            if flags & 0x80 != 0 { cursor += 2 }
            if flags & 0x40 != 0 { cursor += 1 + Int(try data.u8(cursor)) }
            if flags & 0x20 != 0 { cursor += 2 }
            let decoder = try descriptor(cursor, tag: 4)
            let specific = try descriptor(decoder.start + 13, tag: 5)
            guard specific.end <= decoder.end, specific.end - specific.start >= 2 else { throw invalid("AAC 参数异常") }
            return AudioTrack(samples: try samples(data: data, mdhd: mdhd, children: children, table: table),
                              magicCookie: Data(data[(esds.payload + 4)..<esds.end]))
        }
        return nil
    }

    static func annexB(_ sample: Data) throws -> Data {
        var at = 0, result = Data()
        while at <= sample.count - 4 {
            let size = Int(try sample.u32(at)); at += 4
            guard size > 0, size <= sample.count - at else { throw invalid("BVC2 NAL 数据不完整") }
            result.append(contentsOf: [0, 0, 0, 1]); result.append(sample[at..<(at + size)]); at += size
        }
        guard at == sample.count else { throw invalid("BVC2 视频包不完整") }
        return result
    }
}

private extension Data {
    func u8(_ at: Int) throws -> UInt8 {
        guard at >= 0, at < count else { throw VvcSampleIndex.invalid("MP4 元数据越界") }
        return self[at]
    }
    func u16(_ at: Int) throws -> UInt16 { (UInt16(try u8(at)) << 8) | UInt16(try u8(at + 1)) }
    func u32(_ at: Int) throws -> UInt32 { (UInt32(try u16(at)) << 16) | UInt32(try u16(at + 2)) }
    func u64(_ at: Int) throws -> UInt64 { (UInt64(try u32(at)) << 32) | UInt64(try u32(at + 4)) }
    func tag(_ at: Int) throws -> String {
        guard at >= 0, at <= count - 4 else { throw VvcSampleIndex.invalid("MP4 标记越界") }
        return String(decoding: self[at..<(at + 4)], as: UTF8.self)
    }
}
