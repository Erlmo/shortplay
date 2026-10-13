import Cocoa
import FlutterMacOS

// 保留签名库符号：Dart 通过 DynamicLibrary.process() 查找 weeou_sign（同 iOS）。
@_used private let _forceWeeouSign: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?) -> Int32 = weeou_sign

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
