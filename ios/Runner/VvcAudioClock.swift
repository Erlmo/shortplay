import AVFoundation
import Foundation

/// AAC and VVC consume the same demuxed stream on one I/O queue. This avoids
/// AVPlayer performing unrelated file seeks while the VVC decoder is reading.
final class VvcAudioClock {
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let renderer: AVSampleBufferAudioRenderer
    private let audio: VvcSampleIndex.AudioTrack?
    private let queue: DispatchQueue
    private let read: VvcSampleIndex.Read
    private let tryRead: ((Int64, Int) throws -> Data?)?
    private let onError: (Error) -> Void
    private var format: CMAudioFormatDescription?
    private var framesPerPacket: UInt32 = 1024
    private var nextSample = 0
    private let audioBufferLock = NSLock()
    private var enqueuedThroughUs: Int64?
    private var audioRange: Range<Int64>? {
        guard let first = audio?.samples.first, let last = audio?.samples.last else { return nil }
        return first.presentationTimeUs..<(last.presentationTimeUs + last.durationUs)
    }
    private var stopped = false
    private var requesting = false
    private var refillScheduled = false
    private var generation = 0
    private var statusObservation: NSKeyValueObservation?
    private var automaticFlushObserver: NSObjectProtocol?

    init(audio: VvcSampleIndex.AudioTrack?, queue: DispatchQueue,
         read: @escaping VvcSampleIndex.Read,
         tryRead: ((Int64, Int) throws -> Data?)? = nil,
         renderer: AVSampleBufferAudioRenderer = AVSampleBufferAudioRenderer(),
         onError: @escaping (Error) -> Void) throws {
        self.audio = audio
        self.renderer = renderer
        self.queue = queue
        self.read = read
        self.tryRead = tryRead
        self.onError = onError
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        renderer.audioTimePitchAlgorithm = .spectral
        if let audio = audio {
            let description = try Self.formatDescription(for: audio)
            format = description
            framesPerPacket = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee.mFramesPerPacket
            synchronizer.addRenderer(renderer)
            automaticFlushObserver = NotificationCenter.default.addObserver(
                forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                object: renderer, queue: nil) { [weak self] _ in
                    // Rate changes may discard queued AAC without stopping the
                    // master clock. Rewind the sample cursor on the enqueue queue.
                    self?.queue.async { [weak self] in self?.recoverAfterAutomaticFlush() }
                }
            statusObservation = renderer.observe(\.status, options: [.new]) { [weak self] renderer, _ in
                if renderer.status == .failed {
                    let error = renderer.error ?? VvcSampleIndex.invalid("AAC 音频解码失败")
                    DispatchQueue.main.async { self?.onError(error) }
                }
            }
        }
        seek(toMs: 0)
    }

    static func formatDescription(for audio: VvcSampleIndex.AudioTrack) throws -> CMAudioFormatDescription {
        // Use the same full MPEG-4 ES descriptor cookie as AVFoundation.
        // CoreAudio derives the compressed core rate/channels (including HE-AACv2)
        // rather than confusing them with the MP4's decoded output rate/channels.
        var description = AudioStreamBasicDescription()
        description.mFormatID = kAudioFormatMPEG4AAC
        var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = audio.magicCookie.withUnsafeBytes { cookie in
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count),
                                   cookie.baseAddress, &descriptionSize, &description)
        }
        guard formatStatus == noErr, description.mFramesPerPacket > 0 else {
            throw VvcSampleIndex.invalid("AAC 音轨参数异常")
        }
        var result: CMAudioFormatDescription?
        let status = audio.magicCookie.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: cookie.baseAddress,
                extensions: nil, formatDescriptionOut: &result)
        }
        guard status == noErr, let result = result else { throw VvcSampleIndex.invalid("无法初始化 AAC 解码：\(status)") }
        return result
    }

    var currentTime: CMTime { synchronizer.currentTime() }
    var rate: Float { synchronizer.rate }

    // Both clocks stop on underrun. Refill to a higher threshold before
    // resuming to avoid alternating between playing and buffering each frame.
    func hasBufferedAudio(at timeUs: Int64, minimumUs: Int64) -> Bool {
        guard let range = audioRange, range.contains(timeUs) else { return true }
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        return (enqueuedThroughUs ?? Int64.min) >= min(timeUs + minimumUs, range.upperBound)
    }

    private func updateAudioBuffer(through endUs: Int64?) {
        audioBufferLock.lock()
        enqueuedThroughUs = endUs
        audioBufferLock.unlock()
    }

    func setRate(_ rate: Float) {
        if synchronizer.rate != rate {
            synchronizer.setRate(rate, time: synchronizer.currentTime())
        }
        if rate > 0 { queue.async { [weak self] in self?.startRequesting() } }
    }
    func setVolume(_ volume: Float) { renderer.volume = volume }

    func seek(toMs time: Int) {
        let target = CMTime(value: CMTimeValue(max(0, time)), timescale: 1000)
        synchronizer.setRate(0, time: target)
        queue.async { [self] in
            guard !stopped else { return }
            generation += 1
            refillScheduled = false
            stopRequesting()
            renderer.flush()
            updateAudioBuffer(through: nil)
            guard let audio = audio else { return }
            let targetUs = Int64(max(0, time)) * 1000
            nextSample = audio.samples.firstIndex { $0.presentationTimeUs + $0.durationUs > targetUs } ?? audio.samples.count
            nextSample = max(0, nextSample - 1)
            startRequesting()
        }
    }

    /// Serialized with sample enqueueing. A system flush can race an enqueue,
    /// so explicitly clear the remaining future packets before refilling.
    private func recoverAfterAutomaticFlush() {
        guard !stopped, let audio = audio else { return }
        generation += 1
        refillScheduled = false
        stopRequesting()
        renderer.flush()
        updateAudioBuffer(through: nil)
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        guard seconds.isFinite else { return }
        let targetUs = Int64(max(0, seconds) * 1_000_000)
        nextSample = audio.samples.firstIndex {
            $0.presentationTimeUs + $0.durationUs > targetUs
        } ?? audio.samples.count
        nextSample = max(0, nextSample - 1)
        startRequesting()
    }

    private func startRequesting() {
        guard !stopped, !requesting, let audio = audio, nextSample < audio.samples.count else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.fill() }
    }

    private func stopRequesting() {
        renderer.stopRequestingMediaData()
        requesting = false
    }

    /// 真机上切换倍速时，系统可能悄悄清空已排队的音频且不发通知，同步器没有音频可播
    /// 就停住，而这里的记录仍以为音频已排好。按当前时钟位置清空并重新补入，补上后
    /// 播放会自己继续。
    func recoverStalledAudio() {
        queue.async { [weak self] in self?.recoverAfterAutomaticFlush() }
    }

    /// 时钟因音频不足停下时立即补入，不必等下一次轮询。
    func refillNow() {
        queue.async { [weak self] in self?.startRequesting() }
    }

    private func scheduleRefill(whilePaused: Bool = false) {
        guard !stopped, !refillScheduled else { return }
        refillScheduled = true
        let token = generation
        // 切换倍速时同步器可能短暂读到速率为 0。此时若不再安排补入，
        // 排队的音频播完后时钟会因等待音频而停住，补入再也不会被重新触发，
        // 画面就永久卡死。所以暂停时也继续检查，只是间隔放长。
        let delay = whilePaused || synchronizer.rate > 0 ? 0.05 : 0.25
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard self.generation == token else { return }
            self.refillScheduled = false
            self.startRequesting()
        }
    }

    private func fill() {
        guard !stopped, let audio = audio, let format = format else { return }
        do {
            var supplied = 0
            while renderer.isReadyForMoreMediaData, nextSample < audio.samples.count, supplied < 24 {
                let sample = audio.samples[nextSample]
                let currentUs = CMTimeGetSeconds(synchronizer.currentTime()) * 1_000_000
                if currentUs.isFinite, Double(sample.presentationTimeUs) > currentUs + 1_000_000 {
                    // Keep audio near video in the shared range cache; renderer
                    // readiness alone may otherwise read far ahead in the file.
                    stopRequesting()
                    scheduleRefill()
                    return
                }
                let data: Data
                if let tryRead = tryRead {
                    guard let available = try tryRead(sample.offset, sample.size) else {
                        // Future audio is not ready: leave the shared queue free
                        // for current video instead of waiting inside stream IO.
                        stopRequesting()
                        scheduleRefill(whilePaused: true)
                        return
                    }
                    data = available
                } else {
                    data = try read(sample.offset, sample.size)
                }
                guard data.count == sample.size else { throw VvcSampleIndex.invalid("AAC 音频数据读取失败") }
                var block: CMBlockBuffer?
                var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                    memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                    flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                guard status == noErr, let block = block else { throw VvcSampleIndex.invalid("无法分配音频缓冲") }
                status = data.withUnsafeBytes { bytes in
                    CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                                   offsetIntoDestination: 0, dataLength: bytes.count)
                }
                guard status == noErr else { throw VvcSampleIndex.invalid("音频缓冲写入失败") }
                var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: framesPerPacket,
                                                          mDataByteSize: UInt32(data.count))
                var buffer: CMSampleBuffer?
                status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
                    dataBuffer: block, formatDescription: format, sampleCount: 1,
                    presentationTimeStamp: CMTime(value: sample.presentationTimeUs, timescale: 1_000_000),
                    packetDescriptions: &packet, sampleBufferOut: &buffer)
                guard status == noErr, let buffer = buffer else { throw VvcSampleIndex.invalid("AAC 音频包构造失败：\(status)") }
                renderer.enqueue(buffer)
                updateAudioBuffer(through: sample.presentationTimeUs + sample.durationUs)
                nextSample += 1
                supplied += 1
            }
            if nextSample == audio.samples.count { stopRequesting() }
        } catch {
            stopRequesting()
            DispatchQueue.main.async { [weak self] in self?.onError(error) }
        }
    }

    func dispose() {
        synchronizer.setRate(0, time: synchronizer.currentTime())
        if let observer = automaticFlushObserver {
            NotificationCenter.default.removeObserver(observer)
            automaticFlushObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        queue.async { [self] in
            stopped = true
            generation += 1
            stopRequesting()
            renderer.flush()
        }
    }
}
