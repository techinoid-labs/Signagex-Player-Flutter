import UIKit
import Flutter
import Security

@main
@objc class AppDelegate: FlutterAppDelegate {
    
    private let keychainService = "com.example.network"
    private let keychainAccount = "deviceIdentifier"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let deviceIdentifierChannel = FlutterMethodChannel(
            name: "com.example/network",
            binaryMessenger: controller.binaryMessenger
        )

        deviceIdentifierChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "getDeviceIdentifier" {
                if let identifier = self.getOrCreateDeviceIdentifier() {
                    result(identifier)
                } else {
                    result(FlutterError(code: "UNAVAILABLE", message: "Unable to get device identifier", details: nil))
                }
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func getOrCreateDeviceIdentifier() -> String? {
        if let existingIdentifier = loadFromKeychain() {
            return existingIdentifier
        } else {
            let newIdentifier = UUID().uuidString
            saveToKeychain(identifier: newIdentifier)
            return newIdentifier
        }
    }

    private func saveToKeychain(identifier: String) {
        let data = identifier.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject? = nil
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data,
               let result = String(data: data, encoding: .utf8) {
                return result
            }
        }
        return nil
    }
}
