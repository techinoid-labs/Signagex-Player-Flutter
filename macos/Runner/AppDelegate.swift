import Cocoa
import FlutterMacOS
import IOKit
import SystemConfiguration
import CoreGraphics
import ApplicationServices

@main
class AppDelegate: FlutterAppDelegate {
    
    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = self.mainFlutterWindow?.contentViewController as! FlutterViewController
        
        // System Info Channel
        let systemInfoChannel = FlutterMethodChannel(name: "com.example/systemInfo", binaryMessenger: controller.engine.binaryMessenger)
        systemInfoChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "getSystemInfo" {
                result(self.getSystemInformation())
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        let rebootChannel = FlutterMethodChannel(name: "com.example/deviceControl", binaryMessenger: controller.engine.binaryMessenger)
        rebootChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "rebootDevice" {
                self.rebootDevice()
                result("Reboot initiated")
            } else {
                result(FlutterMethodNotImplemented)
            }
        }


            let brightnessChannel = FlutterMethodChannel(name: "com.example/brightnessControl", binaryMessenger: controller.engine.binaryMessenger)
        brightnessChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "setBrightness", let args = call.arguments as? [String: Any],
               let brightness = args["brightness"] as? Float {
                self.setBrightnessLevel(level: brightness)
                result("Brightness set to \(brightness)")
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
        let reloadChannel = FlutterMethodChannel(name: "com.example/reloadApp", binaryMessenger: controller.engine.binaryMessenger)
        reloadChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "reloadApp" {
                self.reloadApp()
                result("App reload initiated")
            } else {
                result(FlutterMethodNotImplemented)
            }
        }




    let volumeChannel = FlutterMethodChannel(name: "com.example/volumeControl", binaryMessenger: controller.engine.binaryMessenger)
    volumeChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        if call.method == "setVolume", let args = call.arguments as? [String: Any],
           let volume = args["volume"] as? Int {
            self.setVolume(volume: volume)
            result("Volume set to \(volume)%")
        } else if call.method == "muteVolume" {
            self.muteVolume()
            result("Volume muted")
        } else if call.method == "unmuteVolume" {
            self.unmuteVolume()
            result("Volume unmuted")
        } else {
            result(FlutterMethodNotImplemented)
        }
    }

    let networkChannel = FlutterMethodChannel(name: "com.example/networkControl", binaryMessenger: controller.engine.binaryMessenger)
        networkChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "restartNetwork" {
                self.restartNetwork()
                result("Network restart initiated")
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

    // Remote View Channel — screenshot capture + cursor/keyboard injection
    // for CMS remote view. In-process only (CGWindowListCreateImage/CGEvent),
    // no subprocesses, since the app runs under App Sandbox.
    let remoteViewChannel = FlutterMethodChannel(name: "com.example/remoteView", binaryMessenger: controller.engine.binaryMessenger)
    remoteViewChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        switch call.method {
        case "captureScreenshot":
            if let data = self.captureOwnWindowJPEG(quality: 0.6) {
                result(FlutterStandardTypedData(bytes: data))
            } else {
                result(FlutterError(code: "CAPTURE_FAILED", message: "Screenshot capture returned nil", details: nil))
            }
        case "moveCursorAndClick":
            if let args = call.arguments as? [String: Any],
               let x = args["x"] as? Double, let y = args["y"] as? Double {
                self.moveCursorAndClick(x: x, y: y)
                result("OK")
            } else {
                result(FlutterError(code: "BAD_ARGS", message: "x/y required", details: nil))
            }
        case "drag":
            if let args = call.arguments as? [String: Any],
               let startX = args["startX"] as? Double, let startY = args["startY"] as? Double,
               let endX = args["endX"] as? Double, let endY = args["endY"] as? Double {
                self.dragCursor(startX: startX, startY: startY, endX: endX, endY: endY)
                result("OK")
            } else {
                result(FlutterError(code: "BAD_ARGS", message: "startX/startY/endX/endY required", details: nil))
            }
        case "typeText":
            if let args = call.arguments as? [String: Any], let text = args["text"] as? String {
                self.typeText(text)
                result("OK")
            } else {
                result(FlutterError(code: "BAD_ARGS", message: "text required", details: nil))
            }
        case "pressHome":
            self.pressHome()
            result("OK")
        case "isAccessibilityTrusted":
            result(self.isAccessibilityTrusted())
        case "requestAccessibilityPermission":
            self.requestAccessibilityPermission()
            result("OK")
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    }

  
    func setBrightnessLevel(level: Float) {
    var iterator: io_iterator_t = 0
    print("Setting brightness to \(level)")

    if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess {
        var service: io_object_t = 1
        var count = 0 

        while service != 0 {
            service = IOIteratorNext(iterator)
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, level)
            IOObjectRelease(service)
            count += 1
        }
        print("Number of displays adjusted: \(count)")
    } else {
        print("Failed to get matching services")
    }
}
func unmuteVolume() {
    let appleScript = """
    set volume output muted false
    """
    var error: NSDictionary?
    if let scriptObject = NSAppleScript(source: appleScript) {
        scriptObject.executeAndReturnError(&error)
        if let error = error {
            print("AppleScript error: \(error)")
        }
    } else {
        print("Failed to create AppleScript object")
    }
}

func reloadApp() {
       
        let appleScript = """
        do shell script "killall -9 \(ProcessInfo.processInfo.processName)"
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        } else {
            print("Failed to create AppleScript object")
        }
    }

        func muteVolume() {
        let appleScript = """
        set volume output muted true
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        } else {
            print("Failed to create AppleScript object")
        }
    }


   func rebootDevice() {
    let appleScript = """
    do shell script "shutdown -r now" with administrator privileges
    """
    var error: NSDictionary?
    if let scriptObject = NSAppleScript(source: appleScript) {
        scriptObject.executeAndReturnError(&error)
        if let error = error {
            print("AppleScript error: \(error)")
        }
    } else {
        print("Failed to create AppleScript object")
    }
}


    func restartNetwork() {
        let appleScript = """
        do shell script "networksetup -setnetworkserviceenabled Wi-Fi off; networksetup -setnetworkserviceenabled Wi-Fi on" with administrator privileges
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        } else {
            print("Failed to create AppleScript object")
        }
    }

    // ────────────────────────────────
    // Remote View — screenshot capture + cursor/keyboard injection
    // ────────────────────────────────

    // Captures only this app's own window (not the whole screen or other
    // apps' windows) via CGWindowListCreateImage. In-process, no
    // subprocess — historically this doesn't require Screen Recording TCC
    // permission the way capturing other processes' windows does.
    func captureOwnWindowJPEG(quality: CGFloat) -> Data? {
        guard let window = self.mainFlutterWindow else { return nil }
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // Moves the real OS cursor and clicks, mirroring xdotool's
    // mousemove+click semantics on Linux. Requires Accessibility trust
    // (see isAccessibilityTrusted) — posts silently do nothing otherwise.
    func moveCursorAndClick(x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func dragCursor(startX: Double, startY: Double, endX: Double, endY: Double) {
        let source = CGEventSource(stateID: .hidSystemState)
        let start = CGPoint(x: startX, y: startY)
        let end = CGPoint(x: endX, y: endY)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // Posting a keycode-based CGEvent can't reliably express arbitrary
    // Unicode text (virtual keycodes are keyboard-layout-dependent).
    // Attaching the text via keyboardSetUnicodeString on a keyDown/keyUp
    // pair is the standard way around that, and the functional analog of
    // `xdotool type -- <text>`.
    func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // No real "home screen" exists to return to on a kiosk running just
    // this app — minimizing is the same WM-agnostic choice made on the
    // Linux branch for the same reason.
    func pressHome() {
        self.mainFlutterWindow?.miniaturize(nil)
    }

    // CGEvent posts to the global HID event stream silently no-op (not an
    // error) unless this app is trusted for Accessibility in System
    // Settings — that trust cannot be granted programmatically. Exposed so
    // the Dart side can surface a clear one-time setup message instead of
    // clicks just doing nothing with no explanation.
    func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func getSystemInformation() -> [String: Any] {
        var systemInfo = [String: Any]()
        
        systemInfo["os_version"] = getOSVersion()
        systemInfo["device_model"] = getDeviceModel()
        systemInfo["network_name"] = getNetworkSSID()
        systemInfo["time_zone"] = getTimeZone()
        systemInfo["cpu_information"] = getCpuInformation()
        systemInfo["memory_information"] = getMemoryInfo()
        systemInfo["storage_info"] = getStorageInfo()
        systemInfo["device_resolution"] = getDeviceResolution()
        systemInfo["battery_information"] = getBatteryInfo()
        systemInfo["camera_details"] = getCameraDetails()
        systemInfo["uuid"] = getUUID()

        return systemInfo
    }


    private func getOSVersion() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }


    private func getDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func getNetworkSSID() -> String {
        return "Not Available"
    }


    private func getTimeZone() -> String {
        return TimeZone.current.identifier
    }


    private func getCpuInformation() -> [String: Any] {
        return [
            "cpu_architecture": getCPUArchitecture(),
            "processor": getProcessorName(),
            "count_cores": getCoreCount()
        ]
    }


    func setVolume(volume: Int) {
        let appleScript = """
        set volume output volume \(volume)
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        } else {
            print("Failed to create AppleScript object")
        }
    }

    private func getCPUArchitecture() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    private func getProcessorName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var cpuName = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &cpuName, &size, nil, 0)
        return String(cString: cpuName)
    }

    private func getCoreCount() -> Int {
        var coreCount: Int = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.physicalcpu", &coreCount, &size, nil, 0)
        return coreCount
    }


    private func getMemoryInfo() -> [String: Any] {
        var vmStat = vm_statistics_data_t()
        var count = UInt32(MemoryLayout<vm_statistics_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_VM_INFO, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pagesize = sysconf(_SC_PAGESIZE)
            let totalMemory = ProcessInfo.processInfo.physicalMemory
            let freeMemory = UInt64(vmStat.free_count) * UInt64(pagesize)
            let usedMemory = totalMemory - freeMemory
            return [
                "total_memory": totalMemory,
                "available_memory": freeMemory,
                "used_memory": usedMemory
            ]
        }
        return [
            "total_memory": 0,
            "available_memory": 0,
            "used_memory": 0
        ]
    }

    // Fetch storage information (total, available)
    private func getStorageInfo() -> [String: Any] {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory() as String)
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            return [
                "total_storage": values.volumeTotalCapacity ?? 0,
                "available_storage": values.volumeAvailableCapacity ?? 0
            ]
        } catch {
            return ["total_storage": 0, "available_storage": 0]
        }
    }

    // Fetch device resolution and pixel density
    private func getDeviceResolution() -> [String: Any] {
        let screen = NSScreen.main
        let resolution = screen?.frame.size ?? NSSize.zero
        let density = screen?.backingScaleFactor ?? 1.0
        return [
            "resolution": "\(Int(resolution.width))x\(Int(resolution.height))",
            "density": density
        ]
    }

    // Fetch battery information
    private func getBatteryInfo() -> [String: Any] {
        var batteryInfo = [
            "battery_percentage": "Not Available",
            "formatted_voltage": "Not Available",
            "formatted_temperature": "Not Available"
        ]

        guard let powerSourceInfo = IOPSCopyPowerSourcesInfo()?.takeUnretainedValue() as? NSDictionary else {
            print("Failed to get power source info")
            return batteryInfo
        }
        
        guard let powerSourcesList = IOPSCopyPowerSourcesList(powerSourceInfo)?.takeUnretainedValue() as? [CFTypeRef] else {
            print("Failed to get power sources list")
            return batteryInfo
        }
        
        for powerSource in powerSourcesList {
            guard let powerSourceDetails = IOPSGetPowerSourceDescription(powerSourceInfo, powerSource)?.takeUnretainedValue() as? [String: Any] else {
                print("Failed to get power source description for \(powerSource)")
                continue
            }
            
            // Extract battery percentage
            if let currentCapacity = powerSourceDetails[kIOPSCurrentCapacityKey as String] as? Int,
               let maxCapacity = powerSourceDetails[kIOPSMaxCapacityKey as String] as? Int {
                let batteryPercentage = Double(currentCapacity) / Double(maxCapacity) * 100
                batteryInfo["battery_percentage"] = String(format: "%.0f%%", batteryPercentage)
            } else {
                print("Battery capacity info is not available")
            }
            
            // Extract voltage and temperature if available
            if let voltage = powerSourceDetails[kIOPSVoltageKey as String] as? Double {
                batteryInfo["formatted_voltage"] = String(format: "%.2f V", voltage)
            }
            
            if let temperature = powerSourceDetails[kIOPSTemperatureKey as String] as? Double {
                batteryInfo["formatted_temperature"] = String(format: "%.2f °C", temperature)
            }
        }

        return batteryInfo
    }

    // Fetch camera details (Currently not available for macOS, placeholder)
    private func getCameraDetails() -> String {
        return "Not Available"
    }

    // Fetch UUID
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
        
        let uuidData = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        IOObjectRelease(platformExpert)
        return uuidData?.takeUnretainedValue() as? String
    }
}
