import Cocoa
import FlutterMacOS
import AVFoundation

class MainFlutterWindow: NSWindow {
  private var nativePlayerPlugin: NativePlayerPlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 竖屏短剧：默认手机比例窗口，可自由缩放
    let size = NSSize(width: 430, height: 900)
    self.setContentSize(size)
    self.contentMinSize = NSSize(width: 360, height: 640)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerNativeChannels(flutterViewController)

    super.awakeFromNib()
  }

  // 与 iOS AppDelegate 中注册的通道一一对应，Dart 侧无需区分平台。
  private func registerNativeChannels(_ controller: FlutterViewController) {
    let registrar = controller.registrar(forPlugin: "ShortplayNativeChannels")
    let messenger = registrar.messenger

    // 原生播放器：AVPlayer + AVAssetResourceLoaderDelegate + FlutterTexture
    let plugin = NativePlayerPlugin(
      messenger: messenger,
      textureRegistry: registrar.textures
    )
    FlutterMethodChannel(name: "shortplay/native_player", binaryMessenger: messenger)
      .setMethodCallHandler { [weak plugin] call, result in
        plugin?.handle(call, result: result)
      }
    FlutterEventChannel(name: "shortplay/native_player/events", binaryMessenger: messenger)
      .setStreamHandler(plugin)
    self.nativePlayerPlugin = plugin

    // UI 通道：macOS 没有 Home 指示条，只实现缩略图截取
    FlutterMethodChannel(name: "com.shortplay/ui", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        switch call.method {
        case "setHomeIndicatorHidden":
          result(nil)
        case "captureVideoThumbnail":
          guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
            result(FlutterError(code: "bad_args", message: "missing path", details: nil))
            return
          }
          MainFlutterWindow.captureVideoThumbnail(path: path) { result($0) }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

    // crypto 解密协议（与 iOS 相同）
    FlutterMethodChannel(name: "shortplay/crypto", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        let args = call.arguments as? [String: Any]
        let url = args?["url"] as? String ?? ""
        let key = args?["key"] as? String ?? ""
        func run(_ work: @escaping () -> Int32) {
          DispatchQueue.global(qos: .userInitiated).async {
            let status = work()
            DispatchQueue.main.async { result(Int(status)) }
          }
        }
        let crypto = CryptoNativePlugin.shared
        switch call.method {
        case "registerCryptoProtocol":
          let handle = (args?["handle"] as? NSNumber)?.int64Value ?? 0
          run { crypto.registerCryptoProtocol(handle: handle) }
        case "prewarm":
          run { crypto.prewarm(cdnUrl: url, keyHex: key) }
        case "prewarmHeaderOnly":
          run { crypto.prewarmHeaderOnly(cdnUrl: url, keyHex: key) }
        case "prewarmSeedMdat":
          run { crypto.prewarmSeedMdat(cdnUrl: url) }
        case "decryptToFile":
          let out = args?["outputPath"] as? String ?? ""
          run { crypto.decryptToFile(cdnUrl: url, keyHex: key, outputPath: out) }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
  }

  private static func captureVideoThumbnail(path: String, completion: @escaping (FlutterStandardTypedData?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      var data: Data?
      if let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
        data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
      }
      DispatchQueue.main.async { completion(data.map { FlutterStandardTypedData(bytes: $0) }) }
    }
  }
}
