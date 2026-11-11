import AVFoundation
import Flutter
import XCTest
@testable import Runner

private final class TextureRegistryProbe: NSObject, FlutterTextureRegistry {
    var textures: [Int64: FlutterTexture] = [:]
    var displayedFrames = 0
    var onFrame: (() -> Void)?
    private var nextId: Int64 = 1

    func register(_ texture: FlutterTexture) -> Int64 {
        let id = nextId
        nextId += 1
        textures[id] = texture
        return id
    }
    func textureFrameAvailable(_ textureId: Int64) {
        guard let buffer = textures[textureId]?.copyPixelBuffer()?.takeRetainedValue() else { return }
        XCTAssertGreaterThan(CVPixelBufferGetWidth(buffer), 0)
        XCTAssertGreaterThan(CVPixelBufferGetHeight(buffer), 0)
        displayedFrames += 1
        onFrame?()
    }
    func unregisterTexture(_ textureId: Int64) { textures.removeValue(forKey: textureId) }
}

/// Set SHORTPLAY_CODEC_FIXTURES to a directory containing real h264/hevc/bvc2
/// MP4s. Media and encryption keys stay outside the repository/test bundle.
final class CodecPlaybackTests: XCTestCase {
    private func fixtures() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SHORTPLAY_CODEC_FIXTURES"] else {
            throw XCTSkip("未指定实际视频样片目录")
        }
        return URL(fileURLWithPath: path)
    }

    func testAudioReadYieldsUntilOnlyItsMissingBytesAreReady() throws {
        let bytes = Data((0..<300000).map { UInt8($0 % 251) })
        var readyEnd: Int64 = 0
        var reads = 0
        let reader = VvcRangeReader(size: Int64(bytes.count), sourceReady: { offset, count in
            offset + Int64(count) <= readyEnd
        }) { offset, count in
            reads += 1
            return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        XCTAssertNil(try reader.readIfAvailable(offset: 196344, count: 363))
        XCTAssertEqual(reads, 0, "等待未来音频不能发起阻塞读取")
        readyEnd = 196707
        let actual = try reader.readIfAvailable(offset: 196344, count: 363)
        XCTAssertEqual(actual, bytes.subdata(in: 196344..<196707))
        XCTAssertEqual(reads, 2)
        readyEnd = 0
        XCTAssertEqual(try reader.readIfAvailable(offset: 196344, count: 363), actual)
        XCTAssertEqual(reads, 2, "已缓存数据不依赖后续网络是否就绪")
    }

    @MainActor
    func testActualH264() throws { try exercise(file: "h264.mp4", backend: "avfoundation") }

    @MainActor
    func testActualHEVC() throws { try exercise(file: "hevc.mp4", backend: "avfoundation") }

    @MainActor
    func testActualBVC2() throws { try exercise(file: "bvc2.mp4", backend: "vvdec") }

    @MainActor
    private func exercise(file: String, backend: String) throws {
        let path = try fixtures().appendingPathComponent(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let registry = TextureRegistryProbe()
        var events: [[String: Any]] = []
        var position = 0
        var duration = 0
        let firstFrame = expectation(description: "实际视频首帧")
        var didRender = false
        let engine = IOSPlaybackEngine(playerId: 1, fileUrl: path.path, textureRegistry: registry) { event in
            events.append(event)
            switch event["type"] as? String {
            case "firstFrame":
                if !didRender { didRender = true; firstFrame.fulfill() }
            case "position": position = event["value"] as? Int ?? 0
            case "duration": duration = event["value"] as? Int ?? 0
            default: break
            }
        }
        defer { engine.dispose() }
        engine.setup()
        engine.play()
        wait(for: [firstFrame], timeout: 15)
        guard didRender else {
            XCTFail("首帧错误：\(events.filter { $0["type"] as? String == "error" })")
            return
        }
        XCTAssertEqual(engine.decodingBackend, backend)
        waitUntil("播放时间前进", timeout: 8) { position > 800 && duration > 1000 }
        XCTAssertGreaterThan(registry.displayedFrames, 5)

        engine.pause()
        spin(0.3)
        let paused = position
        spin(0.4)
        XCTAssertLessThan(abs(position - paused), 100, "暂停后时钟应停止")

        // Resume must work on its own; seeking here used to hide a stuck clock.
        let framesBeforeResume = registry.displayedFrames
        engine.play()
        waitUntil("暂停后直接恢复播放", timeout: 10) {
            position > paused + 400 && registry.displayedFrames > framesBeforeResume + 2
        }

        let frameCount = registry.displayedFrames
        engine.seek(toMs: 3000)
        engine.setRate(1.5)
        engine.play()
        waitUntil("拖动及倍速后继续出画", timeout: 12) {
            position >= 3500 && registry.displayedFrames > frameCount + 3
        }
        let beforeRate = position
        spin(1)
        XCTAssertGreaterThan(position - beforeRate, 1000, "1.5 倍速应加快播放时钟")

        engine.seek(toMs: max(0, duration - 500))
        waitUntil("实际视频播放完成", timeout: 12) {
            events.contains { $0["type"] as? String == "completed" }
        }
        XCTAssertTrue(events.filter { $0["type"] as? String == "error" }.isEmpty,
                      "播放不应报错：\(events.filter { $0["type"] as? String == "error" })")
        engine.dispose()
        XCTAssertTrue(registry.textures.isEmpty)
    }

    @MainActor
    func testBvc2AudioConfigurationMatchesAVFoundation() throws {
        let url = try fixtures().appendingPathComponent("bvc2.mp4")
        let bytes = try Data(contentsOf: url)
        let index = try XCTUnwrap(VvcSampleIndex.load(size: Int64(bytes.count)) { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        })
        let audio = try XCTUnwrap(index.audio)
        let format = try VvcAudioClock.formatDescription(for: audio)
        let asset = AVURLAsset(url: url)
        let loaded = expectation(description: "系统读取实际音轨配置")
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        let native = try XCTUnwrap(asset.tracks(withMediaType: .audio).first?.formatDescriptions.first) as! CMAudioFormatDescription
        let actual = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
        let expected = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(native)).pointee
        XCTAssertEqual(actual.mFormatID, expected.mFormatID)
        XCTAssertEqual(actual.mSampleRate, expected.mSampleRate)
        XCTAssertEqual(actual.mChannelsPerFrame, expected.mChannelsPerFrame)
        XCTAssertEqual(actual.mFramesPerPacket, expected.mFramesPerPacket)
        var cookieSize = 0
        let cookie = try XCTUnwrap(CMAudioFormatDescriptionGetMagicCookie(native, sizeOut: &cookieSize))
        XCTAssertEqual(audio.magicCookie, Data(bytes: cookie, count: cookieSize))
    }

    @MainActor
    func testActualEncryptedBVC2FromCDN() throws { try exerciseEncrypted(codec: "bvc2") }

    @MainActor
    func testActualEncryptedHEVCFromCDN() throws { try exerciseEncrypted(codec: "hevc") }

    @MainActor
    private func exerciseEncrypted(codec: String) throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("manifest.private.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let url = try XCTUnwrap(manifest[codec + "_url"])
        let key = try XCTUnwrap(manifest[codec + "_key"])
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let plugin = try XCTUnwrap(delegate.nativePlayerPlugin)
        var events: [[String: Any]] = []
        var playerId: Int?
        _ = plugin.onListen(withArguments: nil) { raw in
            if let event = raw as? [String: Any] { events.append(event) }
        }
        defer {
            if let id = playerId { plugin.handle(FlutterMethodCall(methodName: "dispose", arguments: ["id": id])) { _ in } }
            _ = plugin.onCancel(withArguments: nil)
        }
        plugin.handle(FlutterMethodCall(methodName: "create", arguments: ["cdnUrl": url, "keyHex": key])) { result in
            playerId = (result as? [String: Any])?["playerId"] as? Int
        }
        let id = try XCTUnwrap(playerId)
        waitUntil("CDN 解密播放器创建", timeout: 20) { events.contains { $0["type"] as? String == "created" } }
        plugin.handle(FlutterMethodCall(methodName: "play", arguments: ["id": id])) { _ in }
        waitUntil("CDN 解密视频首帧", timeout: 20) { events.contains { $0["type"] as? String == "firstFrame" } }
        waitUntil("CDN 解密视频连续播放", timeout: 10) {
            events.contains { $0["type"] as? String == "position" && ($0["value"] as? Int ?? 0) > 1000 }
        }
        let start = events.count
        plugin.handle(FlutterMethodCall(methodName: "seek", arguments: ["id": id, "positionMs": 8000])) { _ in }
        waitUntil("CDN 解密视频拖动后继续播放", timeout: 15) {
            events.dropFirst(start).contains { $0["type"] as? String == "position" && ($0["value"] as? Int ?? 0) > 8300 }
        }
        XCTAssertTrue(events.filter { $0["type"] as? String == "error" }.isEmpty,
                      "CDN 播放出现错误：\(events.filter { $0["type"] as? String == "error" })")
    }

    @MainActor
    func testContinuousActualBvc2EpisodeFromCDN() throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("manifest.private.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let plugin = try XCTUnwrap((UIApplication.shared.delegate as? AppDelegate)?.nativePlayerPlugin)
        var events: [[String: Any]] = []
        var playerId: Int?
        _ = plugin.onListen(withArguments: nil) { raw in
            if let event = raw as? [String: Any] { events.append(event) }
        }
        defer {
            if let id = playerId { plugin.handle(FlutterMethodCall(methodName: "dispose", arguments: ["id": id])) { _ in } }
            _ = plugin.onCancel(withArguments: nil)
        }
        plugin.handle(FlutterMethodCall(methodName: "create", arguments: [
            "cdnUrl": try XCTUnwrap(manifest["bvc2_url"]), "keyHex": try XCTUnwrap(manifest["bvc2_key"])
        ])) { result in playerId = (result as? [String: Any])?["playerId"] as? Int }
        let id = try XCTUnwrap(playerId)
        waitUntil("整集 CDN 播放器准备", timeout: 20) { events.contains { $0["type"] as? String == "created" } }
        plugin.handle(FlutterMethodCall(methodName: "play", arguments: ["id": id])) { _ in }
        let deadline = Date().addingTimeInterval(80)
        var nextLog = Date()
        while Date() < deadline, !events.contains(where: { $0["type"] as? String == "completed" }) {
            spin(0.05)
            if Date() >= nextLog {
                let position = events.last { $0["type"] as? String == "position" }?["value"] ?? -1
                let duration = events.last { $0["type"] as? String == "duration" }?["value"] ?? -1
                let buffering = events.last { $0["type"] as? String == "buffering" }?["value"] ?? false
                print("Continuous BVC2 position=\(position) duration=\(duration) buffering=\(buffering)")
                nextLog = Date().addingTimeInterval(10)
            }
        }
        XCTAssertTrue(events.contains { $0["type"] as? String == "completed" },
                      "连续播放未结束，末尾状态：\(events.suffix(6))")
        XCTAssertTrue(events.contains { $0["type"] as? String == "firstFrame" })
        XCTAssertGreaterThan(events.filter { $0["type"] as? String == "position" }.count, 200)
        XCTAssertTrue(events.filter { $0["type"] as? String == "error" }.isEmpty)
    }

    @MainActor
    func testSwitchBetweenActualCodecs() throws {
        let root = try fixtures()
        let registry = TextureRegistryProbe()
        var current: IOSPlaybackEngine?
        defer { current?.dispose() }
        for (i, name) in ["bvc2.mp4", "hevc.mp4", "bvc2.mp4", "h264.mp4"].enumerated() {
            var firstFrame = false
            var errors: [String] = []
            let next = IOSPlaybackEngine(playerId: 100 + i, fileUrl: root.appendingPathComponent(name).path,
                                          textureRegistry: registry) { event in
                if event["type"] as? String == "firstFrame" { firstFrame = true }
                if event["type"] as? String == "error" { errors.append(String(describing: event["value"])) }
            }
            next.setup()
            // Prepare a frame while the current episode still owns the audio clock.
            next.setVolume(0)
            next.play()
            waitUntil("下一集预备首帧：\(name)", timeout: 15) { firstFrame || !errors.isEmpty }
            XCTAssertTrue(firstFrame, "\(errors)")
            current?.pause()
            current?.dispose()
            current = next
            next.setVolume(1)
            next.play()
            let before = registry.displayedFrames
            waitUntil("切集后继续出画：\(name)", timeout: 5) { registry.displayedFrames > before + 4 }
            XCTAssertEqual(registry.textures.count, 1)
            XCTAssertTrue(errors.isEmpty, "\(errors)")
        }
        current?.dispose()
        XCTAssertTrue(registry.textures.isEmpty)
    }

    @MainActor
    func testDisposeDuringBvc2Preparation() throws {
        let path = try fixtures().appendingPathComponent("bvc2.mp4")
        let registry = TextureRegistryProbe()
        var events = 0
        let engine = IOSPlaybackEngine(playerId: 2, fileUrl: path.path, textureRegistry: registry) { _ in events += 1 }
        engine.setup()
        engine.dispose()
        spin(0.5)
        XCTAssertTrue(registry.textures.isEmpty)
        XCTAssertEqual(events, 0)
    }

    @MainActor
    private func waitUntil(_ description: String, timeout: TimeInterval, condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { spin(0.05) }
        XCTAssertTrue(condition(), description)
    }

    @MainActor
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
