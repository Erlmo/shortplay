import Flutter
import UIKit
import AVFoundation
import CoreVideo

// MARK: - NativePlayerPlugin

final class NativePlayerPlugin: NSObject, FlutterPlugin {
    private let textureRegistry: FlutterTextureRegistry
    private let messenger: FlutterBinaryMessenger
    private var players: [Int: PlayerInstance] = [:]
    private var nextPlayerId: Int = 1
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
        case "create":
            handleCreate(args: args, result: result)
        case "play":
            handlePlay(args: args, result: result)
        case "pause":
            handlePause(args: args, result: result)
        case "seek":
            handleSeek(args: args, result: result)
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
        result(["playerId": playerId, "textureId": -1])

        if keyHex.isEmpty {
            // 本地文件或普通 URL，不走 crypto stream
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let instance = PlayerInstance(
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
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let handle = sp_stream_open(cdnUrl, keyHex)
                guard let handle = handle else {
                    DispatchQueue.main.async {
                        self.sendEvent([
                            "playerId": playerId,
                            "type": "error",
                            "value": "sp_stream_open failed"
                        ])
                    }
                    return
                }

                DispatchQueue.main.async {
                    let instance = PlayerInstance(
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
        lock.unlock()
        guard let player = player else {
            result(FlutterError(code: "not_found", message: "Player not found", details: nil))
            return
        }
        player.dispose()
        result(nil)
    }

    // MARK: - Helpers

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
    private var displayLink: CADisplayLink?
    private var timeObserver: Any?
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    private var firstFrameSent = false

    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var bufferingObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?

    private let resourceLoaderQueue = DispatchQueue(label: "com.shortplay.resourceloader", qos: .userInitiated)
    private var resourceLoaderDelegate: CryptoResourceLoaderDelegate?
    private var disposed = false

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

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        self.videoOutput = output

        let item: AVPlayerItem

        if let filePath = fileUrl {
            // 本地文件或普通 URL，直接创建 AVPlayerItem
            let url: URL
            if filePath.hasPrefix("http://") || filePath.hasPrefix("https://") {
                url = URL(string: filePath)!
            } else {
                url = URL(fileURLWithPath: filePath)
            }
            item = AVPlayerItem(url: url)
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

        setupObservers()
        setupDisplayLink()
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
                let size = item.presentationSize
                if size.width > 0 && size.height > 0 {
                    self.eventCallback([
                        "playerId": self.playerId,
                        "type": "videoSize",
                        "width": Int(size.width),
                        "height": Int(size.height)
                    ])
                }
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
        guard let output = videoOutput else { return }
        let currentTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: currentTime) else { return }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else { return }

        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()

        textureRegistry.textureFrameAvailable(textureId)

        if !firstFrameSent {
            firstFrameSent = true
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
        player?.rate = currentRate
    }

    func pause() {
        player?.pause()
    }

    func seek(toMs ms: Int) {
        let time = CMTime(value: CMTimeValue(ms), timescale: 1000)
        player?.seek(to: time)
    }

    func setVolume(_ volume: Float) {
        player?.volume = volume
    }

    func setRate(_ rate: Float) {
        currentRate = rate
        player?.rate = rate
    }

    // MARK: - Dispose

    func dispose() {
        guard !disposed else { return }
        disposed = true

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

        resourceLoaderDelegate?.invalidate()

        if let handle = streamHandle {
            let loaderQueue = resourceLoaderQueue
            loaderQueue.async {
                sp_stream_close(handle)
            }
        }

        resourceLoaderDelegate = nil
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
