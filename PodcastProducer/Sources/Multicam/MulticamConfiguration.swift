import Foundation

/// Gdje je relay za telefone-kamere i kojom se sobom i ključem spaja.
/// Protokol: multicam/PROTOCOL.md. Isti relay i ista soba kao `director.mjs`.
struct MulticamConfiguration: Codable, Equatable {
    var isEnabled = false
    var relayURL = "https://domovina-multicam-relay.d-o-m.workers.dev"
    var room = "studio"

    var relay: URL? {
        URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ključ relaya: Keychain, a ako ga tamo nema, ista datoteka koju čita
    /// `director.mjs` — na Macu gdje multicam već radi iz terminala ne treba
    /// ništa upisivati.
    var key: String? {
        if let stored = MulticamConfigurationStore.loadKey(), !stored.isEmpty { return stored }
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/domovina-multicam/key")
        let fromFile = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fromFile?.isEmpty == false ? fromFile : nil
    }

    var isUsable: Bool { isEnabled && relay != nil && !room.isEmpty && key != nil }

    /// Sadržaj QR koda za spajanje telefona (aplikacija ga otvara kao deep link).
    /// Kodira se sve osim neograničenih znakova, kao `URLSearchParams` u director.mjs.
    func joinURL(name: String? = nil) -> String? {
        guard let relay, let key else { return nil }
        var items = [("relay", relay.absoluteString), ("room", room), ("key", key)]
        if let name, !name.isEmpty { items.append(("name", name)) }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = items
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return "domovinacam://join?\(query)"
    }

    /// Isto što `segment()` u relayu: tako relay od sessionId-a slaže ključ
    /// objekta u R2, pa Post mora isto da bi našao snimke te sesije.
    static func pathSegment(_ value: String) -> String {
        let decomposed = value.decomposedStringWithCompatibilityMapping
        var clean = decomposed.replacingOccurrences(of: "[^A-Za-z0-9_.-]+", with: "-", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "^[-.]+|-+$", with: "", options: .regularExpression)
        return String(clean.prefix(80))
    }
}

enum MulticamConfigurationStore {
    private static let defaultsKey = "multicam.configuration"
    private static let keychainService = "tv.domovina.studio.multicam"
    private static let keychainAccount = "relay-key"

    static func load() -> MulticamConfiguration {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(MulticamConfiguration.self, from: data) else {
            return MulticamConfiguration()
        }
        return configuration
    }

    static func save(_ configuration: MulticamConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func saveKey(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
