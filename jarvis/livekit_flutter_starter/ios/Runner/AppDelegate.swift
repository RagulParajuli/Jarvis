import Flutter
import UIKit
import Security

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        let registrar = self.registrar(forPlugin: "JarvisSecureAccessCode")!
        let channel = FlutterMethodChannel(name: "jarvis/device", binaryMessenger: registrar.messenger())
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "readSavedAccessCode":
                result(Self.readSavedAccessCode())
            case "saveAccessCode":
                guard let arguments = call.arguments as? [String: Any],
                      let value = arguments["value"] as? String,
                      !value.isEmpty else {
                    result(FlutterError(code: "invalid_argument", message: "Access code is empty", details: nil))
                    return
                }
                Self.saveAccessCode(value, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private static let accessCodeService = Bundle.main.bundleIdentifier ?? "jarvis"
    private static let accessCodeAccount = "jarvis-access-code"

    private static func readSavedAccessCode() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: accessCodeService,
            kSecAttrAccount as String: accessCodeAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveAccessCode(_ value: String, result: FlutterResult) {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: accessCodeService,
            kSecAttrAccount as String: accessCodeAccount
        ]
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = key
            update.forEach { insert[$0.key] = $0.value }
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            result(insertStatus == errSecSuccess ? nil : FlutterError(
                code: "keychain_error", message: "Could not save access code", details: insertStatus
            ))
        } else {
            result(status == errSecSuccess ? nil : FlutterError(
                code: "keychain_error", message: "Could not save access code", details: status
            ))
        }
    }
}
