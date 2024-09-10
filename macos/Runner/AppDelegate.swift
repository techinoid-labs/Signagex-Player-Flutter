import Cocoa
import FlutterMacOS
import IOKit

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = self.mainFlutterWindow?.contentViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.example/network", binaryMessenger: controller.engine.binaryMessenger)

    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "getDeviceIdentifier" {
        result(self.getUUID())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func getUUID() -> String {
    if let uuid = getPlatformUUID() {
      return uuid
    }
    return UUID().uuidString // Fallback to a generated UUID if system UUID isn't available
  }

  private func getPlatformUUID() -> String? {
    let platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard platformExpert != 0 else {
      return nil
    }
    
    let uuid = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String
    IOObjectRelease(platformExpert)
    return uuid
  }
}
