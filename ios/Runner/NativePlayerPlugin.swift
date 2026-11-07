import Flutter
import UIKit
import AVFoundation
import CoreVideo

// MARK: - NativePlayerPlugin

final class NativePlayerPlugin: NSObject, FlutterPlugin {
    private let textureRegistry: FlutterTextureRegistry
    private let messenger: FlutterBinaryMessenger
    private var players: [Int: IOSPlaybackEngine] = [:]
    private var nextPlayerId: Int = 1
    private var pendingCreates = Set<Int>()
    private var eventSink: FlutterEventSink?
    private let lock = NSLock()

    init(messenger: FlutterBinaryMessenger, textureRegistry: FlutterTextureRegistry) {
        self.messenger = messenger
        self.textureRegistry = textureRegistry
        super.init()
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        let textureRegistry = registrar.textures()
        let instance = NativePlayerPlugin(messenger: messenger, textureRegistry: textureRegistry)

        let methodChannel = FlutterMethodChannel(
            name: "shortplay/native_player",
            binaryMessenger: messenger
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "shortplay/native_player/events",
            binaryMessenger: messenger
        )
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - MethodChannel Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "supportsBvc2":
            result(true)
        case "create":
            handleCreate(args: args, result: result)
        case "play":
            handlePlay(args: args, result: result)
        case "pause":
            handlePause(args: args, result: result)
        case "seek":
            handleSeek(args: args, result: result)
        case "setActive":
            handleSetActive(args: args, result: result)
        case "setVolume":
            handleSetVolume(args: args, result: result)
        case "setRate":
            handleSetRate(args: args, result: result)
        case "dispose":
            handleDispose(args: args, result: result)
        case "setKeepScreenOn":
            let on = args?["on"] as? Bool ?? false
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = on
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method Implementations

    func handleCreate(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let cdnUrl = args?["cdnUrl"] as? String,
              let keyHex = args?["keyHex"] as? String else {
            result(FlutterError(code: "bad_args", message: "cdnUrl and keyHex required", details: nil))
            return
        }

        let playerId = self.nextPlayerId
        self.nextPlayerId += 1
        lock.lock()
        pendingCreates.insert(playerId)
        lock.unlock()
        result(["playerId": playerId, "textureId": -1])

        if keyHex.isEmpty {
            // 本地文件或普通 URL，不走 crypto stream
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.takePendingCreate(playerId) else { return }
                let instance = IOSPlaybackEngine(
                    playerId: playerId,
                    fileUrl: cdnUrl,
                    textureRegistry: self.textureRegistry,
                    eventSink: { [weak self] event in self?.sendEvent(event) }
                )
                self.lock.lock()
                self.players[playerId] = instance
                self.lock.unlock()

                instance.setup()

                self.sendEvent([
                    "playerId": playerId,
                    "type": "created",
                    "value": instance.textureId
                ])
            }
        } else {
            CryptoNativePlugin.shared.ensureInit()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let handle = sp_stream_open(cdnUrl, keyHex)
                guard let handle = handle else {
                    DispatchQueue.main.async {
                        guard self.takePendingCreate(playerId) else { return }
                        self.sendEvent([
                            "playerId": playerId,
                            "type": "error",
                            "value": "sp_stream_open failed"
                        ])
                    }
                    return
                }

                DispatchQueue.main.async {
                    guard self.takePendingCreate(playerId) else {
                        DispatchQueue.global(qos: .utility).async { sp_stream_close(handle) }
                        return
                    }
                    let instance = IOSPlaybackEngine(
                        playerId: playerId,
                        streamHandle: handle,
                        textureRegistry: self.textureRegistry,
                        eventSink: { [weak self] event in self?.sendEvent(event) }
                    )
                    self.lock.lock()
                    self.players[playerId] = instance
                    self.lock.unlock()

                    instance.setup()

                    self.sendEvent([
                        "playerId": playerId,
                        "type": "created",
                        "value": instance.textureId
                    ])
                }
            }
        }
    }

    private func handlePlay(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? Int, let player = getPlayer(id) else {
            result(FlutterError(code: "not_found", message: "Player not found", details: nil))
            return
        }
        player.play()
        result(nil)
    }

    private func handlePause(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? Int, let player = getPlayer(id) else {
            result(FlutterError(code: "not_found", message: "Player not found", details: nil))
            return
        }
        player.pause()
        result(nil)
    }

    private func handleSeek(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? Int, let player = getPlayer(id) else {
            result(FlutterError(code: "not_found", message: "Player not found", details: nil))
            return
        }
        let positionMs = args?["positionMs"] as? Int ?? 0
        player.seek(toMs: positionMs)
        result(nil)
    }

    private func handleSetActive(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? Int, let player = getPlayer(id) else {
            result(FlutterError(code: "not_found", message: "Player not found", details: nil))
            return
        }
        player.setActive(args?["active"] as? Bool ?? true)
        result(nil)
    }

    private func handleSetVolume(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? Int, let player = getPlayer(id) else {
            result(FlutterError(code: "not_found", message: "Player not found", details: nil))
            return
        }
        let volume = args?["volume"] as? Double ?? 1.0
        player.setVolume(Float(volume))
        result(nil)
    }

    private func handleSetRate(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? Int, let player = getPlayer(id) else {
            result(FlutterError(code: "not_found", message: "Player not found", details: nil))
            return
        }
        let rate = args?["rate"] as? Double ?? 1.0
        player.setRate(Float(rate))
        result(nil)
    }

    func handleDispose(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let id = args?["id"] as? Int else {
            result(FlutterError(code: "bad_args", message: "id required", details: nil))
            return
        }
        lock.lock()
        let player = players.removeValue(forKey: id)
        let cancelledCreate = pendingCreates.remove(id) != nil
        lock.unlock()
        if cancelledCreate { result(nil); return }
        guard let player = player else {
            result(FlutterError(code: "not_found", message: "Player not found", details: nil))
            return
        }
        player.dispose()
        result(nil)
    }

    // MARK: - Helpers

    private func takePendingCreate(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingCreates.remove(id) != nil
    }

    private func getPlayer(_ id: Int) -> IOSPlaybackEngine? {
        lock.lock()
        let p = players[id]
        lock.unlock()
        return p
    }

    private func sendEvent(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }
}

// MARK: - FlutterStreamHandler

extension NativePlayerPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}

// MARK: - IOSPlaybackEngine

final class IOSPlaybackEngine: NSObject, FlutterTexture {
    let playerId: Int
    private var streamHandle: UnsafeMutableRawPointer?
    private var fileUrl: String?
    private let textureRegistry: FlutterTextureRegistry
    private let eventCallback: ([String: Any]) -> Void
    private(set) var textureId: Int64 = -1

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var timeObserver: Any?
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    private var firstFrameSent = false

    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var bufferingObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var lastSentVideoSize = CGSize.zero

    private let resourceLoaderQueue = DispatchQueue(label: "com.shortplay.resourceloader", qos: .userInitiated)
    private var resourceLoaderDelegate: CryptoResourceLoaderDelegate?
    private var disposed = false
    private var wantsPlaying = false
    private var pendingSeekMs: Int?
    private var currentVolume: Float = 1
    private var vvcPlayback: VvcPlayback?
    private var vvcAudioClock: VvcAudioClock?
    private var vvcDurationMs = 0
    private var vvcLastPositionMs = -200
    private var vvcCompleted = false
    private var reportedPlaying = false
    private var vvcBuffering = false
    private var vvcFrameTimeUs: Int64 = -1
    private var localSourceFile: FileHandle?
    private var vvcReadCache: VvcRangeReader?
    private var sourceAsset: AVURLAsset?

    /// Exposed internally for native codec regression tests.
    private(set) var decodingBackend = "avfoundation"

    init(playerId: Int, streamHandle: UnsafeMutableRawPointer,
         textureRegistry: FlutterTextureRegistry,
         eventSink: @escaping ([String: Any]) -> Void) {
        self.playerId = playerId
        self.streamHandle = streamHandle
        self.textureRegistry = textureRegistry
        self.eventCallback = eventSink
        super.init()
    }

    init(playerId: Int, fileUrl: String,
         textureRegistry: FlutterTextureRegistry,
         eventSink: @escaping ([String: Any]) -> Void) {
        self.playerId = playerId
        self.fileUrl = fileUrl
        self.textureRegistry = textureRegistry
        self.eventCallback = eventSink
        super.init()
    }

    // MARK: - Setup

    func setup() {
        textureId = textureRegistry.register(self)
        let asset: AVURLAsset
        let shouldProbe: Bool
        if let path = fileUrl {
            let url: URL
            if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("file://") {
                guard let parsed = URL(string: path) else {
                    fail(VvcSampleIndex.invalid("视频地址无效"))
                    return
                }
                url = parsed
            } else {
                url = URL(fileURLWithPath: path)
            }
            asset = AVURLAsset(url: url)
            shouldProbe = url.isFileURL
        } else if let handle = streamHandle {
            resourceLoaderDelegate = CryptoResourceLoaderDelegate(streamHandle: handle, queue: resourceLoaderQueue)
            asset = AVURLAsset(url: URL(string: "spcrypto://player_\(playerId)")!)
            asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: resourceLoaderQueue)
            shouldProbe = true
        } else {
            fail(VvcSampleIndex.invalid("缺少视频数据源"))
            return
        }
        sourceAsset = asset
        guard shouldProbe else {
            configure(asset: asset, vvcIndex: nil)
            return
        }
        resourceLoaderQueue.async { [self] in
            do {
                let size: Int64
                if let handle = streamHandle {
                    size = sp_stream_size(handle)
                } else {
                    let file = try FileHandle(forReadingFrom: asset.url)
                    localSourceFile = file
                    size = Int64(try file.seekToEnd())
                }
                let index = try VvcSampleIndex.load(size: size, read: readMediaBytes)
                if index != nil, streamHandle != nil {
                    vvcReadCache = VvcRangeReader(size: size) { [weak self] offset, count in
                        guard let self = self else { throw VvcSampleIndex.invalid("播放器已关闭") }
                        return try self.readRawMediaBytes(offset: offset, count: count)
                    }
                }
                DispatchQueue.main.async { [self] in
                    guard !disposed else { return }
                    configure(asset: asset, vvcIndex: index)
                }
            } catch {
                DispatchQueue.main.async { [self] in fail(error) }
            }
        }
    }

    /// Both video demux and AVPlayer resource loading are confined to resourceLoaderQueue.
    private func readMediaBytes(offset: Int64, count: Int) throws -> Data {
        if let cache = vvcReadCache { return try cache.read(offset: offset, count: count) }
        return try readRawMediaBytes(offset: offset, count: count)
    }

    private func readRawMediaBytes(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw VvcSampleIndex.invalid("视频读取范围无效") }
        if let file = localSourceFile {
            try file.seek(toOffset: UInt64(offset))
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw VvcSampleIndex.invalid("本地视频文件不完整") }
            return data
        }
        guard let handle = streamHandle, sp_stream_seek(handle, offset) >= 0 else {
            throw VvcSampleIndex.invalid("视频数据定位失败")
        }
        var data = Data(count: count)
        var done = 0
        try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            while done < count {
                let pointer = bytes.baseAddress!.advanced(by: done).assumingMemoryBound(to: CChar.self)
                let n = sp_stream_read(handle, pointer, UInt64(count - done))
                guard n > 0 else { throw VvcSampleIndex.invalid("视频数据读取中断") }
                done += Int(n)
            }
        }
        return data
    }

    private func configure(asset: AVURLAsset, vvcIndex: VvcSampleIndex?) {
        guard !disposed else { return }
        if let index = vvcIndex {
            decodingBackend = "vvdec"
            vvcBuffering = true
            sendVideoSize(CGSize(width: index.width, height: index.height))
            do {
                vvcAudioClock = try VvcAudioClock(audio: index.audio, queue: resourceLoaderQueue,
                    read: readMediaBytes, onError: { [weak self] error in self?.fail(error) })
                vvcAudioClock?.setVolume(currentVolume)
            } catch { fail(error); return }
            vvcDurationMs = Int(index.samples.map { $0.presentationTimeUs + $0.durationUs }.max() ?? 0) / 1000
            eventCallback(["playerId": playerId, "type": "duration", "value": vvcDurationMs])
            vvcPlayback = VvcPlayback(index: index, queue: resourceLoaderQueue, read: readMediaBytes,
                                      onAvailable: { [weak self] in self?.displayLinkFired() },
                                      onError: { [weak self] error in self?.fail(error) })
            vvcPlayback?.start()
            setupDisplayLink()
            if let ms = pendingSeekMs {
                pendingSeekMs = nil
                seek(toMs: ms)
            }
        } else {
            attachPlayer(item: AVPlayerItem(asset: asset), video: true)
        }
    }

    private func attachPlayer(item: AVPlayerItem, video: Bool) {
        if video {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            videoOutput = output
            item.add(output)
        }
        playerItem = item
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        player = avPlayer
        avPlayer.volume = currentVolume
        setupObservers()
        if let ms = pendingSeekMs {
            pendingSeekMs = nil
            seek(toMs: ms)
        }
        if displayLink == nil { setupDisplayLink() }
        applyPlaybackState()
    }

    private func fail(_ error: Error) {
        guard !disposed else { return }
        wantsPlaying = false
        player?.pause()
        vvcAudioClock?.setRate(0)
        eventCallback(["playerId": playerId, "type": "error", "value": error.localizedDescription])
    }

    private func applyPlaybackState() {
        guard !disposed else { return }
        let rate = wantsPlaying && !vvcBuffering ? currentRate : 0
        if let clock = vvcAudioClock {
            clock.setRate(rate)
            if reportedPlaying != (rate > 0) {
                reportedPlaying = rate > 0
                eventCallback(["playerId": playerId, "type": "playing", "value": rate > 0])
            }
        } else { player?.rate = rate }
    }

    // MARK: - Observers

    private func setupObservers() {
        guard let item = playerItem, let avPlayer = player else { return }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            if item.status == .failed {
                DispatchQueue.main.async { self.fail(item.error ?? VvcSampleIndex.invalid("播放器加载失败")) }
                return
            }
            if item.status == .readyToPlay {
                DispatchQueue.main.async { self.applyPlaybackState() }
                let durationMs = Int(CMTimeGetSeconds(item.duration) * 1000)
                self.eventCallback([
                    "playerId": self.playerId,
                    "type": "duration",
                    "value": durationMs
                ])
                self.sendVideoSize(item.presentationSize)
            }
        }

        durationObservation = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            if item.duration != .indefinite {
                let durationMs = Int(CMTimeGetSeconds(item.duration) * 1000)
                self.eventCallback([
                    "playerId": self.playerId,
                    "type": "duration",
                    "value": durationMs
                ])
            }
        }

        bufferingObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            self.eventCallback([
                "playerId": self.playerId,
                "type": "buffering",
                "value": item.isPlaybackBufferEmpty
            ])
        }

        // readyToPlay 时 presentationSize 可能还是 0，之后才变成真实尺寸；
        // 只在 readyToPlay 上报会导致 Dart 侧一直按默认 9:16 画面（横屏片源被拉伸）。
        presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            self?.sendVideoSize(item.presentationSize)
        }

        rateObservation = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self = self else { return }
            self.eventCallback([
                "playerId": self.playerId,
                "type": "playing",
                "value": player.rate > 0
            ])
        }

        let interval = CMTime(value: 200, timescale: 1000)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let positionMs = Int(CMTimeGetSeconds(time) * 1000)
            self.eventCallback([
                "playerId": self.playerId,
                "type": "position",
                "value": positionMs
            ])
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    /// 视频尺寸有效且变化时上报（KVO / 首帧都可能调用，去重）。
    private func sendVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != lastSentVideoSize else { return }
        lastSentVideoSize = size
        eventCallback([
            "playerId": playerId,
            "type": "videoSize",
            "width": Int(size.width),
            "height": Int(size.height)
        ])
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        eventCallback([
            "playerId": playerId,
            "type": "completed",
            "value": true
        ])
    }

    // MARK: - DisplayLink

    private func setupDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
        } else {
            link.preferredFramesPerSecond = 60
        }
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    @objc private func displayLinkFired() {
        guard !disposed else { return }
        let pixelBuffer: CVPixelBuffer
        if let decoder = vvcPlayback {
            let seconds = vvcAudioClock.map { CMTimeGetSeconds($0.currentTime) } ?? 0
            let timeUs = seconds.isFinite ? Int64(seconds * 1_000_000) : 0
            let positionMs = min(vvcDurationMs, max(0, Int(timeUs / 1000)))
            if abs(positionMs - vvcLastPositionMs) >= 200 {
                vvcLastPositionMs = positionMs
                eventCallback(["playerId": playerId, "type": "position", "value": positionMs])
            }
            // Audio and video may end a fraction of one video frame apart.
            // Once the last decoded picture was presented, that rounding gap
            // must not leave the episode waiting forever for an exact timestamp.
            if !vvcCompleted && (positionMs >= vvcDurationMs ||
                (decoder.ended && positionMs >= vvcDurationMs - 50)) {
                vvcCompleted = true
                wantsPlaying = false
                applyPlaybackState()
                eventCallback(["playerId": playerId, "type": "position", "value": vvcDurationMs])
                eventCallback(["playerId": playerId, "type": "completed", "value": true])
            }
            guard let frame = decoder.takeFrame(at: timeUs) else {
                if firstFrameSent, !decoder.ended, timeUs > vvcFrameTimeUs + 200_000, !vvcBuffering {
                    vvcBuffering = true
                    applyPlaybackState()
                    eventCallback(["playerId": playerId, "type": "buffering", "value": true])
                }
                return
            }
            pixelBuffer = frame.pixelBuffer
            vvcFrameTimeUs = frame.presentationTimeUs
            if vvcBuffering {
                vvcBuffering = false
                eventCallback(["playerId": playerId, "type": "buffering", "value": false])
                applyPlaybackState()
            }
        } else {
            guard let output = videoOutput else { return }
            let currentTime = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: currentTime),
                  let buffer = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else { return }
            pixelBuffer = buffer
        }

        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()

        textureRegistry.textureFrameAvailable(textureId)

        if !firstFrameSent {
            firstFrameSent = true
            // 兜底：首帧时还没拿到 presentationSize，就用像素缓冲的宽高
            if lastSentVideoSize == .zero {
                sendVideoSize(CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                     height: CVPixelBufferGetHeight(pixelBuffer)))
            }
            eventCallback([
                "playerId": playerId,
                "type": "firstFrame",
                "value": true
            ])
        }
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        bufferLock.lock()
        let pb = latestPixelBuffer
        bufferLock.unlock()
        guard let pixelBuffer = pb else { return nil }
        return Unmanaged.passRetained(pixelBuffer)
    }

    // MARK: - Player Controls

    private var currentRate: Float = 1.0

    func play() {
        wantsPlaying = true
        applyPlaybackState()
    }

    func pause() {
        wantsPlaying = false
        applyPlaybackState()
    }

    func seek(toMs ms: Int) {
        guard player != nil || vvcAudioClock != nil else { pendingSeekMs = ms; return }
        let time = CMTime(value: CMTimeValue(max(0, ms)), timescale: 1000)
        if let decoder = vvcPlayback {
            vvcBuffering = true
            applyPlaybackState()
            eventCallback(["playerId": playerId, "type": "buffering", "value": true])
            vvcCompleted = false
            vvcLastPositionMs = -200
            vvcAudioClock?.seek(toMs: ms)
            decoder.seek(toMs: ms)
        } else {
            player?.seek(to: time)
        }
    }

    func setVolume(_ volume: Float) {
        currentVolume = volume
        player?.volume = volume
        vvcAudioClock?.setVolume(volume)
    }

    /// Park (false) / unpark (true) the crypto stream. A parked stream stops
    /// fetching ~1MB past its read position so a paused prev/next player does
    /// not compete for bandwidth with the on-screen episode.
    func setActive(_ active: Bool) {
        guard !disposed, let handle = streamHandle else { return }
        sp_stream_set_active(handle, active ? 1 : 0)
    }

    func setRate(_ rate: Float) {
        currentRate = rate
        applyPlaybackState()
    }

    // MARK: - Dispose

    func dispose() {
        guard !disposed else { return }
        disposed = true
        vvcPlayback?.dispose()
        vvcPlayback = nil
        vvcAudioClock?.dispose()
        vvcAudioClock = nil

        displayLink?.invalidate()
        displayLink = nil

        if let observer = timeObserver, let avPlayer = player {
            avPlayer.removeTimeObserver(observer)
        }
        timeObserver = nil

        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        bufferingObservation?.invalidate()
        bufferingObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = nil

        NotificationCenter.default.removeObserver(self)

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        videoOutput = nil

        textureRegistry.unregisterTexture(textureId)

        bufferLock.lock()
        latestPixelBuffer = nil
        bufferLock.unlock()

        // Abort before invalidating: a loader-queue read blocked on a parked
        // stream must return, or the sp_stream_close queued below never runs.
        if let handle = streamHandle {
            sp_stream_abort(handle)
        }

        resourceLoaderDelegate?.invalidate()

        if let handle = streamHandle {
            let loaderQueue = resourceLoaderQueue
            loaderQueue.async {
                sp_stream_close(handle)
            }
        }

        resourceLoaderDelegate = nil
        sourceAsset = nil
        resourceLoaderQueue.async { [weak self] in
            try? self?.localSourceFile?.close()
            self?.localSourceFile = nil
            self?.vvcReadCache = nil
        }
    }

    deinit {
        dispose()
    }
}

// MARK: - CryptoResourceLoaderDelegate

private final class CryptoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let streamHandle: UnsafeMutableRawPointer
    private let workQueue: DispatchQueue
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private let requestLock = NSLock()
    private var invalidated = false

    init(streamHandle: UnsafeMutableRawPointer, queue: DispatchQueue) {
        self.streamHandle = streamHandle
        self.workQueue = queue
        super.init()
    }

    func invalidate() {
        requestLock.lock()
        invalidated = true
        let pending = pendingRequests
        pendingRequests.removeAll()
        requestLock.unlock()
        for request in pending {
            if !request.isFinished && !request.isCancelled {
                request.finishLoading(with: NSError(domain: "NativePlayer", code: -1, userInfo: nil))
            }
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        requestLock.lock()
        if invalidated {
            requestLock.unlock()
            return false
        }
        pendingRequests.append(loadingRequest)
        requestLock.unlock()

        workQueue.async { [weak self] in
            self?.processRequest(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        requestLock.lock()
        pendingRequests.removeAll { $0 === loadingRequest }
        requestLock.unlock()
    }

    // MARK: - Request Processing

    private func processRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        // Fill content information if requested
        if let infoRequest = loadingRequest.contentInformationRequest {
            let totalSize = sp_stream_size(streamHandle)
            infoRequest.contentLength = totalSize
            infoRequest.contentType = "public.mpeg-4"
            infoRequest.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            finishRequest(loadingRequest, error: nil)
            return
        }

        let totalSize = sp_stream_size(streamHandle)
        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = dataRequest.requestedLength
        let currentOffset = dataRequest.currentOffset

        // Compute desired range
        var startOffset = currentOffset
        if startOffset < requestedOffset {
            startOffset = requestedOffset
        }

        var bytesRemaining: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            bytesRemaining = totalSize > 0 ? (totalSize - startOffset) : Int64.max
        } else {
            let endOffset = requestedOffset + Int64(requestedLength)
            bytesRemaining = endOffset - startOffset
        }

        if bytesRemaining <= 0 {
            finishRequest(loadingRequest, error: nil)
            return
        }

        // Seek to start position (instant, no network)
        let seekResult = sp_stream_seek(streamHandle, startOffset)
        if seekResult < 0 {
            finishRequest(loadingRequest, error: NSError(domain: "NativePlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "seek failed"]))
            return
        }

        // Read in chunks
        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        while bytesRemaining > 0 {
            // Check cancellation
            requestLock.lock()
            let isInvalidated = invalidated
            let stillPending = pendingRequests.contains { $0 === loadingRequest }
            requestLock.unlock()
            if isInvalidated || !stillPending || loadingRequest.isCancelled {
                return
            }

            let toRead = min(UInt64(bytesRemaining), UInt64(chunkSize))
            let bytesRead = sp_stream_read(streamHandle, buffer, toRead)
            if bytesRead < 0 {
                finishRequest(loadingRequest, error: NSError(domain: "NativePlayer", code: Int(bytesRead), userInfo: [NSLocalizedDescriptionKey: "read failed"]))
                return
            }
            if bytesRead == 0 {
                // EOF
                break
            }

            let data = Data(bytes: buffer, count: Int(bytesRead))
            dataRequest.respond(with: data)
            bytesRemaining -= bytesRead
        }

        finishRequest(loadingRequest, error: nil)
    }

    private func finishRequest(_ request: AVAssetResourceLoadingRequest, error: Error?) {
        requestLock.lock()
        pendingRequests.removeAll { $0 === request }
        requestLock.unlock()
        if request.isFinished || request.isCancelled { return }
        if let error = error {
            request.finishLoading(with: error)
        } else {
            request.finishLoading()
        }
    }
}
