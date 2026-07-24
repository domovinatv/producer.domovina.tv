import Foundation
import Security

/// R2 connection settings. The secret access key is stored in the login
/// Keychain; everything else lives in UserDefaults so it can be inspected.
struct R2Configuration: Codable, Equatable {
    var accountID: String = ""
    var bucket: String = ""
    var accessKeyID: String = ""
    var prefix: String = "sessions"
    var isEnabled: Bool = false
    /// Upload audio segments and video chunks while the take is running.
    var uploadDuringRecording: Bool = true
    /// Upload the full-quality master files once recording stops.
    var uploadMastersAfterStop: Bool = true

    var endpoint: URL? {
        guard !accountID.isEmpty else { return nil }
        return URL(string: "https://\(accountID).r2.cloudflarestorage.com")
    }

    var isUsable: Bool {
        isEnabled && !accountID.isEmpty && !bucket.isEmpty && !accessKeyID.isEmpty
    }
}

enum R2ConfigurationStore {

    private static let defaultsKey = "r2.configuration"
    private static let keychainService = "tv.domovina.studio.r2"

    static func load() -> R2Configuration {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(R2Configuration.self, from: data) else {
            return R2Configuration()
        }
        return configuration
    }

    static func save(_ configuration: R2Configuration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Keychain

    static func saveSecret(_ secret: String, forAccessKeyID accessKeyID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accessKeyID
        ]
        SecItemDelete(query as CFDictionary)

        guard !secret.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadSecret(forAccessKeyID accessKeyID: String) -> String? {
        guard !accessKeyID.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accessKeyID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasSecret(forAccessKeyID accessKeyID: String) -> Bool {
        loadSecret(forAccessKeyID: accessKeyID) != nil
    }
}
