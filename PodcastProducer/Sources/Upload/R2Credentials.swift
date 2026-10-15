import Foundation
import Security
import CryptoKit

/// Reads the account and bucket straight out of a Cloudflare dashboard URL.
///
/// The account ID is a 32-character hex string nobody retypes correctly, and it
/// is sitting in the address bar of the page you are already looking at. Pasting
/// that URL is both faster and less error-prone than copying two fields.
enum R2DashboardURL {

    struct Parsed: Equatable {
        var accountID: String
        /// Nil on pages that are not about one specific bucket (overview, tokens).
        var bucket: String?
    }

    static func parse(_ input: String) -> Parsed? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Accept a bare paste without the scheme, which is what you get from
        // some browsers' "copy address".
        let normalised = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: normalised),
              let host = url.host?.lowercased(),
              host == "dash.cloudflare.com" || host.hasSuffix(".dash.cloudflare.com")
        else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let accountID = parts.first, isAccountID(accountID) else { return nil }

        // `/r2/<jurisdiction>/buckets/<name>/…` — the jurisdiction segment is
        // "default" for most accounts but "eu" or "fedramp" elsewhere, so the
        // bucket is found by looking for the marker rather than by position.
        var bucket: String?
        if let marker = parts.firstIndex(of: "buckets"), parts.index(after: marker) < parts.endIndex {
            let candidate = parts[parts.index(after: marker)]
            if !candidate.isEmpty { bucket = candidate.removingPercentEncoding ?? candidate }
        }

        return Parsed(accountID: accountID, bucket: bucket)
    }

    /// Cloudflare account IDs are 32 lowercase hex characters.
    private static func isAccountID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Where the S3 access keys are made. Wrangler cannot create them; only this
    /// page can.
    static func apiTokensPage(accountID: String) -> URL? {
        guard isAccountID(accountID) else { return nil }
        return URL(string: "https://dash.cloudflare.com/\(accountID)/r2/api-tokens")
    }
}

/// Turns one Cloudflare API token into the S3 credentials R2 signs with.
///
/// R2's S3 endpoint speaks SigV4, which needs an access key and a secret — a
/// bearer token cannot be used directly. But the two are derived from the token
/// rather than being separate facts: the access key ID *is* the token's ID, and
/// the secret is the SHA-256 of the token value. So one token really is enough,
/// provided it carries R2 read and write permission.
enum R2TokenCredentials {

    enum DerivationError: LocalizedError {
        case rejected(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .rejected(let detail): return "Cloudflare je odbio token: \(detail)"
            case .malformedResponse: return "Neočekivan odgovor pri provjeri tokena."
            }
        }
    }

    /// The secret is a pure function of the token — no network needed.
    static func secretAccessKey(forToken token: String) -> String {
        let digest = SHA256.hash(data: Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The access key ID is the token's own ID, which only Cloudflare can tell us.
    static func accessKeyID(forToken token: String, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!)
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DerivationError.malformedResponse
        }
        guard root["success"] as? Bool == true else {
            let errors = (root["errors"] as? [[String: Any]])?
                .compactMap { $0["message"] as? String }
                .joined(separator: ", ")
            throw DerivationError.rejected(errors?.isEmpty == false ? errors! : "nepoznat razlog")
        }
        guard let result = root["result"] as? [String: Any], let id = result["id"] as? String else {
            throw DerivationError.malformedResponse
        }
        return id
    }
}

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
