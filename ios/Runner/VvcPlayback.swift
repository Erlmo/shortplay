import Foundation
import CoreVideo
import ShortplayVvc

/// Main-thread frame queue, backed by a serial demux/decode queue. Audio remains
/// the sample-buffer master clock, so pause, rate and seek use the same time base.
final class VvcPlayback {
    private let index: VvcSampleIndex
    private let queue: DispatchQueue
    private let read: VvcSampleIndex.Read
    private let onAvailable: () -> Void
    private let onError: (Error) -> Void
    private var frames: [SPVvcFrame] = []
    private var pending = false
    private var disposed = false
    private var generation = 0
    private var finished = false

    // These fields are confined to queue, including decoder destruction.
    private var decoder: SPVvcDecoder?
    private var nextSample = 0
    private var minimumTimeUs: Int64 = 0

    init(index: VvcSampleIndex, queue: DispatchQueue, read: @escaping VvcSampleIndex.Read,
         onAvailable: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.index = index
        self.queue = queue
        self.read = read
        self.onAvailable = onAvailable
        self.onError = onError
    }

    func start() { seek(toMs: 0) }

    func seek(toMs time: Int) {
        guard !disposed else { return }
        generation += 1
        let token = generation
        frames.removeAll()
        finished = false
        pending = true
        let target = Int64(max(0, time)) * 1000
        var sync = 0
        for (i, sample) in index.samples.enumerated() where sample.sync && sample.presentationTimeUs <= target {
            sync = i
        }
        let firstSample = sync
        queue.async { [self] in
            do {
                decoder = try SPVvcDecoder(threadCount: 2)
                nextSample = firstSample
                minimumTimeUs = target
                _ = try decoder?.decodePacket(index.configuration, presentationTimeUs: 0)
                DispatchQueue.main.async { [self] in
                    guard !disposed, generation == token else { return }
                    pending = false
                    pump()
                }
            } catch { report(error, generation: token) }
        }
    }

    func takeFrame(at timeUs: Int64) -> SPVvcFrame? {
        guard !disposed else { return nil }
        var result: SPVvcFrame?
        while let first = frames.first, first.presentationTimeUs <= timeUs + 16_667 {
            result = frames.removeFirst()
        }
        pump()
        return result
    }

    var ended: Bool { finished && frames.isEmpty }

    private func pump() {
        guard !disposed, !pending, !finished, frames.count < 10 else { return }
        pending = true
        let token = generation
        queue.async { [self] in
            do {
                var output: SPVvcFrame?
                var eof = false
                // Yield the I/O queue periodically so the audio renderer can read packets.
                for _ in 0..<24 {
                    if nextSample < index.samples.count {
                        let sample = index.samples[nextSample]
                        nextSample += 1
                        let bytes = try read(sample.offset, sample.size)
                        guard bytes.count == sample.size else { throw VvcSampleIndex.invalid("BVC2 视频数据读取失败") }
                        output = (try decoder?.decodePacket(VvcSampleIndex.annexB(bytes),
                                                            presentationTimeUs: sample.presentationTimeUs))?.first
                    } else {
                        output = (try decoder?.flush())?.first
                        if output == nil { eof = true; break }
                    }
                    if let frame = output, frame.presentationTimeUs >= minimumTimeUs - 16_667 { break }
                    output = nil
                }
                let frame = output, complete = eof
                DispatchQueue.main.async { [self] in
                    guard !disposed, generation == token else { return }
                    pending = false
                    if let frame = frame { frames.append(frame) }
                    finished = complete
                    onAvailable()
                    pump()
                }
            } catch { report(error, generation: token) }
        }
    }

    private func report(_ error: Error, generation token: Int) {
        DispatchQueue.main.async { [self] in
            guard !disposed, generation == token else { return }
            pending = false
            finished = true
            onError(error)
        }
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        generation += 1
        frames.removeAll()
        queue.async { [self] in decoder = nil }
    }
}
