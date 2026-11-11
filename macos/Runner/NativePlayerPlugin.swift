// macOS 版原生播放器：移植自 ios/Runner/NativePlayerPlugin.swift。
// 差异：FlutterMacOS、用 Timer 代替 CADisplayLink 取帧、IOSurface/Metal
// 兼容的像素缓冲、用 ProcessInfo activity 代替 isIdleTimerDisabled。
// 改播放逻辑时请两边同步。

import FlutterMacOS
import AppKit
import AVFoundation
import CoreVideo

// MARK: - NativePlayerPlugin

final class NativePlayerPlugin: NSObject {
    private let textureRegistry: FlutterTextureRegistry
    private let messenger: FlutterBinaryMessenger
    private var players: [Int: PlayerInstance] = [:]
    private var nextPlayerId: Int = 1
    private var pendingCreates = Set<Int>()
    private var eventSink: FlutterEventSink?
    private let lock = NSLock()

    init(messenger: FlutterBinaryMessenger, textureRegistry: FlutterTextureRegistry) {
        self.messenger = messenger
        self.textureRegistry = textureRegistry
        super.init()
    }

    // MARK: - MethodChannel Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "mediaCacheDirectory":
            result(MediaByteCache.shared.root.path)
        case "registerMediaSource":
            guard let primary = args?["primaryUrl"] as? String,
                  let urls = args?["urls"] as? [String] else {
                result(FlutterError(code: "bad_args", message: "primaryUrl and urls required", details: nil))
                return
            }
            MediaSourceRegistry.shared.register(primary: primary, urls: urls,
                expiresAt: (args?["expiresAt"] as? NSNumber)?.doubleValue)
            result(nil)
        case "create":
            handleCreate(args: args, result: result)
        case "getBufferState":
            guard let id = args?["id"] as? Int else {
                result(nil)
                return
            }
            // Queries must remain available when the playback clock is stopped.
            // Do not start a timer or change rate/buffering state here.
            DispatchQueue.main.async { [weak self] in
                result(self?.getPlayer(id)?.bufferState())
            }
        case "prepareFirstFrame":
            guard let id = args?["id"] as? Int, let player = getPlayer(id) else {
                result(FlutterError(code: "not_found", message: "Player not found", details: nil))
                return
            }
            player.prepareFirstFrame()
            result(nil)
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
            DispatchQueue.main.async { [weak self] in
                self?.setKeepScreenOn(on)
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

        let initialPositionMs = max(0, (args?["initialPositionMs"] as? NSNumber)?.intValue ?? 0)

        let playerId = self.nextPlayerId
        self.nextPlayerId += 1
        lock.lock(); pendingCreates.insert(playerId); lock.unlock()
        result(["playerId": playerId, "textureId": -1])

        if keyHex.isEmpty {
            // 本地文件或普通 URL，不走 crypto stream
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.takePendingCreate(playerId) else { return }
                let instance = PlayerInstance(
                    playerId: playerId,
                    fileUrl: cdnUrl,
                    textureRegistry: self.textureRegistry,
                    eventSink: { [weak self] event in self?.sendEvent(event) }
                )
                self.lock.lock()
                self.players[playerId] = instance
                self.lock.unlock()

                instance.setInitialPosition(initialPositionMs)
                instance.setup()

                self.sendEvent([
                    "playerId": playerId,
                    "type": "created",
                    "value": instance.textureId
                ])
            }
        } else {
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
                    let instance = PlayerInstance(
                        playerId: playerId,
                        streamHandle: handle,
                        textureRegistry: self.textureRegistry,
                        eventSink: { [weak self] event in self?.sendEvent(event) }
                    )
                    self.lock.lock()
                    self.players[playerId] = instance
                    self.lock.unlock()

                    instance.setInitialPosition(initialPositionMs)
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

    private var screenActivity: NSObjectProtocol?

    private func setKeepScreenOn(_ on: Bool) {
        if on {
            guard screenActivity == nil else { return }
            screenActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Video playback"
            )
        } else if let activity = screenActivity {
            ProcessInfo.processInfo.endActivity(activity)
            screenActivity = nil
        }
    }

    private func takePendingCreate(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingCreates.remove(id) != nil
    }

    private func getPlayer(_ id: Int) -> PlayerInstance? {
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

// MARK: - PlayerInstance

private final class PlayerInstance: NSObject, FlutterTexture {
    let playerId: Int
    private var streamHandle: UnsafeMutableRawPointer?
    private var fileUrl: String?
    private let textureRegistry: FlutterTextureRegistry
    private let eventCallback: ([String: Any]) -> Void
    private(set) var textureId: Int64 = -1

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: Timer?
    private var timeObserver: Any?
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    private var avCompleted = false
    private var firstFrameSent = false
    private var preRenderRequested = false
    private var prerollInFlight = false
    private var prerollGeneration = 0
    private var playerStatusObservation: NSKeyValueObservation?

    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var bufferingObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var lastSentVideoSize = CGSize.zero

    private let resourceLoaderQueue = DispatchQueue(label: "com.shortplay.resourceloader", qos: .userInitiated)
    private var resourceLoaderDelegate: CryptoResourceLoaderDelegate?
    private var mediaResourceLoader: MediaCacheResourceLoader?
    private var mediaSourceRangeProbeDone = false
    private var mediaSourceUseLegacy = false
    private let mediaSourceProbeCancellation = MediaReadCancellation()
    private var initialPositionPending = false
    private var initialSeekGeneration = 0
    private var disposed = false
    private var wantsPlaying = false
    private var pendingSeekMs: Int?
    private var currentVolume: Float = 1

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

    func setInitialPosition(_ milliseconds: Int) {
        guard milliseconds > 0 else { return }
        pendingSeekMs = milliseconds
        initialPositionPending = true
    }

    private func seekInitialPosition(_ milliseconds: Int, in avPlayer: AVPlayer) {
        initialPositionPending = true
        initialSeekGeneration += 1
        let generation = initialSeekGeneration
        avPlayer.pause()
        let time = CMTime(value: CMTimeValue(max(0, milliseconds)), timescale: 1000)
        avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak avPlayer] finished in
            DispatchQueue.main.async {
                guard let self = self, !self.disposed,
                      self.player === avPlayer, self.initialSeekGeneration == generation else { return }
                guard finished else {
                    self.eventCallback(["playerId": self.playerId, "type": "error", "value": "初始播放位置定位失败"])
                    return
                }
                self.initialPositionPending = false
                self.applyPlaybackState()
                self.startPendingPreroll()
                self.displayLinkFired()
            }
        }
    }

    // MARK: - Setup

    func setup() {
        guard !disposed else { return }
        if textureId < 0 { textureId = textureRegistry.register(self) }
        // Multi-CDN plain HTTP needs our Range IO. Probe one bounded prefix
        // first; a non-Range origin explicitly keeps its original URLAsset path.
        if let path = fileUrl, MediaSourceRegistry.valid(path),
           !mediaSourceRangeProbeDone,
           MediaSourceRegistry.shared.context(path).hasAlternates,
           MediaByteCache.shared.metadata(MediaSourceRegistry.shared.context(path).currentURL) == nil {
            mediaSourceRangeProbeDone = true
            resourceLoaderQueue.async { [self] in
                do {
                    _ = try MediaCacheReader(url: path, cancellation: mediaSourceProbeCancellation)
                        .read(offset: 0, count: MediaByteCache.blockSize)
                } catch {
                    let failure = MediaNetworkFailure.classify(error)
                    if case .rangeUnsupported = failure.kind {
                        DispatchQueue.main.async { [self] in
                            guard !disposed else { return }; mediaSourceUseLegacy = true; setup()
                        }
                        return
                    }
                    DispatchQueue.main.async { [self] in
                        guard !disposed else { return }
                        eventCallback(["playerId": playerId, "type": "error", "value": "视频网络请求失败"])
                    }
                    return
                }
                DispatchQueue.main.async { [self] in guard !disposed else { return }; setup() }
            }
            return
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        self.videoOutput = output

        let item: AVPlayerItem

        if let filePath = fileUrl {
            // 本地文件或普通 URL，直接创建 AVPlayerItem
            let url: URL
            if filePath.hasPrefix("http://") ||
                filePath.hasPrefix("https://") ||
                filePath.hasPrefix("file://") {
                url = URL(string: filePath)!
            } else {
                url = URL(fileURLWithPath: filePath)
            }
            // Preserve original AVPlayer streaming for uncached/non-Range
            // origins. A successful SDK prefetch opts the source into cache IO.
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               !mediaSourceUseLegacy,
               MediaByteCache.shared.metadata(MediaSourceRegistry.shared.context(filePath).currentURL) != nil {
                let loader = MediaCacheResourceLoader(source: filePath, queue: resourceLoaderQueue)
                mediaResourceLoader = loader
                let asset = AVURLAsset(url: URL(string: "spmedia://player_\(playerId)/video.mp4")!)
                asset.resourceLoader.setDelegate(loader, queue: resourceLoaderQueue)
                item = AVPlayerItem(asset: asset)
            } else {
                item = AVPlayerItem(url: url)
            }
        } else if let handle = streamHandle {
            // crypto stream 路径
            resourceLoaderDelegate = CryptoResourceLoaderDelegate(
                streamHandle: handle,
                queue: resourceLoaderQueue
            )
            let url = URL(string: "spcrypto://player_\(playerId)")!
            let asset = AVURLAsset(url: url)
            asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: resourceLoaderQueue)
            item = AVPlayerItem(asset: asset)
        } else {
            return
        }

        item.add(output)
        self.playerItem = item

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        self.player = avPlayer
        avPlayer.volume = currentVolume
        setupObservers()
        if let ms = pendingSeekMs {
            pendingSeekMs = nil
            seekInitialPosition(ms, in: avPlayer)
        }
        setupDisplayLink()
        applyPlaybackState()
    }

    // MARK: - Observers

    private func setupObservers() {
        guard let item = playerItem, let avPlayer = player else { return }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            if item.status == .readyToPlay {
                let durationMs = Int(CMTimeGetSeconds(item.duration) * 1000)
                self.eventCallback([
                    "playerId": self.playerId,
                    "type": "duration",
                    "value": durationMs
                ])
                self.sendVideoSize(item.presentationSize)
                DispatchQueue.main.async { self.startPendingPreroll() }
            }
        }

        playerStatusObservation = avPlayer.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startPendingPreroll() }
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
            let seconds = CMTimeGetSeconds(time)
            var bufferedEnd = seconds
            if seconds.isFinite, let item = self.player?.currentItem {
                for value in item.loadedTimeRanges {
                    let range = value.timeRangeValue
                    let start = CMTimeGetSeconds(range.start)
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                    if start.isFinite && end.isFinite && start <= bufferedEnd + 0.05 && end > bufferedEnd {
                        bufferedEnd = end
                    }
                }
                self.eventCallback([
                    "playerId": self.playerId,
                    "type": "bufferedAhead",
                    "value": max(0, Int((bufferedEnd - seconds) * 1000))
                ])
            }
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
        avCompleted = true
        eventCallback([
            "playerId": playerId,
            "type": "completed",
            "value": true
        ])
    }

    // MARK: - DisplayLink

    private func setupDisplayLink() {
        // macOS 13 及以下没有 CADisplayLink；60Hz Timer 轮询 hasNewPixelBuffer 即可。
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.displayLinkFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.displayLink = timer
    }

    @objc private func displayLinkFired() {
        guard !disposed, !initialPositionPending, let output = videoOutput else { return }
        let currentTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: currentTime) else { return }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else { return }

        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()

        textureRegistry.textureFrameAvailable(textureId)

        if !firstFrameSent {
            firstFrameSent = true
            cancelPrerollPreparation()
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

    /// Side-effect-free native state snapshot for the SDK's buffer monitor.
    /// Unknown/indefinite timestamps remain null, never fabricated zeroes.
    func bufferState() -> [String: Any]? {
        guard !disposed else { return nil }
        let position = player.flatMap { Self.milliseconds($0.currentTime()) }
        let duration = playerItem.flatMap { Self.milliseconds($0.duration) }
        var buffered: Int?
        if let avPlayer = player {
            let seconds = CMTimeGetSeconds(avPlayer.currentTime())
            if seconds.isFinite && seconds >= 0, let item = playerItem {
                let ranges = item.loadedTimeRanges.compactMap { value -> (Double, Double)? in
                    let range = value.timeRangeValue
                    let start = CMTimeGetSeconds(range.start)
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                    guard start.isFinite, end.isFinite, end >= start else { return nil }
                    return (start, end)
                }.sorted { $0.0 < $1.0 }
                var end = seconds
                for range in ranges {
                    // Match the existing contiguous-range tolerance; disjoint
                    // later ranges must not be counted as playable headroom.
                    if range.0 <= end + 0.05 && range.1 > end { end = range.1 }
                }
                let milliseconds = (end - seconds) * 1000
                if milliseconds.isFinite, milliseconds >= 0,
                   milliseconds < Double(Int.max) {
                    buffered = Int(milliseconds)
                }
            }
        }
        return [
            "bufferedAheadMs": buffered as Any? ?? NSNull(),
            "positionMs": position as Any? ?? NSNull(),
            "durationMs": duration as Any? ?? NSNull(),
            "buffering": playerItem?.isPlaybackBufferEmpty == true ||
                player?.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            "playing": (player?.rate ?? 0) > 0,
            "completed": avCompleted
        ]
    }

    private static func milliseconds(_ time: CMTime) -> Int? {
        let value = CMTimeGetSeconds(time) * 1000
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }

    // MARK: - Player Controls

    private var currentRate: Float = 1.0

    /// Prime the existing engine without moving its media clock. Completion
    /// of preroll is not a first-frame event: displayLinkFired must still
    /// publish an actual pixel buffer before Dart can reuse this instance.
    func prepareFirstFrame() {
        guard !disposed else { return }
        setVolume(0)
        pause()
        preRenderRequested = !firstFrameSent
        startPendingPreroll()
    }

    private func startPendingPreroll() {
        guard !disposed, !initialPositionPending, preRenderRequested, !prerollInFlight,
              let avPlayer = player, avPlayer.rate == 0,
              avPlayer.status == .readyToPlay,
              playerItem?.status == .readyToPlay else { return }
        prerollInFlight = true
        let generation = prerollGeneration
        avPlayer.preroll(atRate: 1) { [weak self, weak avPlayer] finished in
            DispatchQueue.main.async {
                guard let self = self, !self.disposed,
                      self.player === avPlayer,
                      self.prerollGeneration == generation else { return }
                self.prerollInFlight = false
                guard self.preRenderRequested else { return }
                if finished {
                    self.displayLinkFired()
                } else {
                    self.preRenderRequested = false
                    self.eventCallback(["playerId": self.playerId, "type": "error",
                                        "value": "首帧预渲染准备失败"])
                }
            }
        }
    }

    private func cancelPrerollPreparation() {
        prerollGeneration += 1
        preRenderRequested = false
        prerollInFlight = false
        player?.cancelPendingPrerolls()
    }

    func play() {
        cancelPrerollPreparation()
        wantsPlaying = true
        applyPlaybackState()
    }

    private func applyPlaybackState() {
        guard !disposed else { return }
        player?.rate = wantsPlaying && !initialPositionPending ? currentRate : 0
    }

    func pause() {
        wantsPlaying = false
        player?.pause()
    }

    func seek(toMs ms: Int) {
        avCompleted = false
        guard let avPlayer = player else { pendingSeekMs = max(0, ms); return }
        let time = CMTime(value: CMTimeValue(max(0, ms)), timescale: 1000)
        if initialPositionPending { seekInitialPosition(ms, in: avPlayer) }
        else { avPlayer.seek(to: time) }
    }

    func setVolume(_ volume: Float) {
        currentVolume = volume
        player?.volume = volume
    }

    /// Park (false) / unpark (true) the crypto stream. A parked stream stops
    /// fetching ~1MB past its read position so a paused prev/next player does
    /// not compete for bandwidth with the on-screen episode.
    func setActive(_ active: Bool) {
        guard !disposed else { return }
        mediaResourceLoader?.setActive(active)
        if let handle = streamHandle { sp_stream_set_active(handle, active ? 1 : 0) }
    }

    func setRate(_ rate: Float) {
        currentRate = rate
        applyPlaybackState()
    }

    // MARK: - Dispose

    func dispose() {
        guard !disposed else { return }
        disposed = true
        initialSeekGeneration += 1
        mediaSourceProbeCancellation.cancel()
        cancelPrerollPreparation()
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil

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
        mediaResourceLoader?.invalidate()

        if let handle = streamHandle {
            let loaderQueue = resourceLoaderQueue
            loaderQueue.async {
                sp_stream_close(handle)
            }
        }

        resourceLoaderDelegate = nil
        mediaResourceLoader = nil
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
        requestLock.lock()
        let active = !invalidated && pendingRequests.contains { $0 === loadingRequest }
        requestLock.unlock()
        guard active, !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
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

        // One bounded slice per turn: a request-to-EOF must not monopolize
        // the serial stream and block AVPlayer's other track/header requests.
        // Re-seek on each turn because another request may use the same handle.
        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        let toRead = min(UInt64(bytesRemaining), UInt64(chunkSize))
        let bytesRead = sp_stream_read(streamHandle, buffer, toRead)
        if bytesRead < 0 {
            finishRequest(loadingRequest, error: NSError(domain: "NativePlayer", code: Int(bytesRead),
                userInfo: [NSLocalizedDescriptionKey: "read failed"]))
            return
        }
        requestLock.lock()
        let stillActive = !invalidated && pendingRequests.contains { $0 === loadingRequest }
        requestLock.unlock()
        guard stillActive, !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
        if bytesRead == 0 {
            finishRequest(loadingRequest, error: nil)
            return
        }
        dataRequest.respond(with: Data(bytes: buffer, count: Int(bytesRead)))
        if bytesRemaining > bytesRead {
            workQueue.async { [weak self] in self?.processRequest(loadingRequest) }
        } else {
            finishRequest(loadingRequest, error: nil)
        }
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
