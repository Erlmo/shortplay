import Flutter
import UIKit
import AVFoundation

// 自定义 FlutterViewController，控制 Home 指示条隐藏
class MainFlutterViewController: FlutterViewController {
  override var prefersHomeIndicatorAutoHidden: Bool {
    if #available(iOS 11.0, *) {
      return HomeIndicatorState.shared.isHidden
    }
    return false
  }
}

@_used private let _forceWeeouSign: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?) -> Int32 = weeou_sign

@main
@objc class AppDelegate: FlutterAppDelegate {
  var flutterEngine: FlutterEngine?
  var nativePlayerPlugin: NativePlayerPlugin?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 配置音频会话为 .playback：视频播放无视硬件静音键，静音模式下仍有声音
    configureAudioSession()

    // 预热并持有全局 FlutterEngine，避免黑屏
    let engine = FlutterEngine(name: "main_engine")
    self.flutterEngine = engine
    engine.run()
    GeneratedPluginRegistrant.register(with: engine)

    // 使用自定义控制器作为根控制器
    if self.window == nil {
      self.window = UIWindow(frame: UIScreen.main.bounds)
    }
    let controller = MainFlutterViewController(engine: engine, nibName: nil, bundle: nil)
    self.window?.rootViewController = controller
    self.window?.makeKeyAndVisible()

    // 原生播放器：基于 AVPlayer + AVAssetResourceLoaderDelegate + FlutterTexture
    let nativePlayerPlugin = NativePlayerPlugin(
      messenger: controller.binaryMessenger,
      textureRegistry: controller
    )
    let nativePlayerMethodChannel = FlutterMethodChannel(
      name: "shortplay/native_player",
      binaryMessenger: controller.binaryMessenger
    )
    nativePlayerMethodChannel.setMethodCallHandler { [weak nativePlayerPlugin] call, result in
      nativePlayerPlugin?.handle(call, result: result)
    }
    let nativePlayerEventChannel = FlutterEventChannel(
      name: "shortplay/native_player/events",
      binaryMessenger: controller.binaryMessenger
    )
    nativePlayerEventChannel.setStreamHandler(nativePlayerPlugin)
    self.nativePlayerPlugin = nativePlayerPlugin

    // 原生通道：UI 控制（Home 指示条等）
    let channel = FlutterMethodChannel(name: "com.shortplay/ui", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setHomeIndicatorHidden":
        if let args = call.arguments as? [String: Any], let hidden = args["hidden"] as? Bool {
          if #available(iOS 11.0, *) {
            HomeIndicatorState.shared.isHidden = hidden
            controller.setNeedsUpdateOfHomeIndicatorAutoHidden()
            result(nil)
          } else {
            result(FlutterError(code: "not_available", message: "Requires iOS 11+", details: nil))
          }
        } else {
          result(FlutterError(code: "bad_args", message: "missing hidden", details: nil))
        }
      case "captureVideoThumbnail":
        if let args = call.arguments as? [String: Any], let path = args["path"] as? String {
          self.captureVideoThumbnail(path: path) { data in
            result(data)
          }
        } else {
          result(FlutterError(code: "bad_args", message: "missing path", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // 原生通道：crypto 解密协议
    let cryptoChannel = FlutterMethodChannel(name: "shortplay/crypto", binaryMessenger: controller.binaryMessenger)
    cryptoChannel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "registerCryptoProtocol":
        let handle = (args?["handle"] as? NSNumber)?.int64Value ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
          let status = CryptoNativePlugin.shared.registerCryptoProtocol(handle: handle)
          DispatchQueue.main.async { result(Int(status)) }
        }
      case "prewarm":
        let cdnUrl = args?["url"] as? String ?? ""
        let keyHex = args?["key"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
          let status = CryptoNativePlugin.shared.prewarm(cdnUrl: cdnUrl, keyHex: keyHex)
          DispatchQueue.main.async { result(Int(status)) }
        }
      case "prewarmHeaderOnly":
        let cdnUrl = args?["url"] as? String ?? ""
        let keyHex = args?["key"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
          let status = CryptoNativePlugin.shared.prewarmHeaderOnly(cdnUrl: cdnUrl, keyHex: keyHex)
          DispatchQueue.main.async { result(Int(status)) }
        }
      case "prewarmSeedMdat":
        let cdnUrl = args?["url"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
          let status = CryptoNativePlugin.shared.prewarmSeedMdat(cdnUrl: cdnUrl)
          DispatchQueue.main.async { result(Int(status)) }
        }
      case "decryptToFile":
        let cdnUrl = args?["url"] as? String ?? ""
        let keyHex = args?["key"] as? String ?? ""
        let outputPath = args?["outputPath"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
          let status = CryptoNativePlugin.shared.decryptToFile(cdnUrl: cdnUrl, keyHex: keyHex, outputPath: outputPath)
          DispatchQueue.main.async { result(Int(status)) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

extension AppDelegate {
  /// 配置 AVAudioSession 为 .playback，使视频在硬件静音开关打开时仍能播放声音。
  /// 默认 category 为 .soloAmbient，会跟随静音键被静音。
  func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      NSLog("配置 AVAudioSession 失败: \(error.localizedDescription)")
    }
  }

  func captureVideoThumbnail(path: String, completion: @escaping (FlutterStandardTypedData?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let url = URL(fileURLWithPath: path)
      let asset = AVURLAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero

      let time = CMTime(seconds: 0.1, preferredTimescale: 600)
      do {
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: 0.82) else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        DispatchQueue.main.async {
          completion(FlutterStandardTypedData(bytes: data))
        }
      } catch {
        DispatchQueue.main.async {
          completion(nil)
        }
      }
    }
  }
}

// 全局状态：控制 Home 指示条隐藏
class HomeIndicatorState {
  static let shared = HomeIndicatorState()
  var isHidden: Bool = false
}
