import Foundation
import CryptoKit

/// Minimal AWS Signature V4 signer, which is what Cloudflare R2's S3-compatible
/// API expects (region is always `auto`, service is always `s3`).
///
/// Signing happens in-process so a recording never depends on a signing server
/// being reachable. Credentials live in the macOS Keychain, never on disk.
enum SigV4 {

    /// R2 ignores the region but requires it to be present and consistent.
    static let region = "auto"
    static let service = "s3"

    struct Credentials {
        var accessKeyID: String
        var secretAccessKey: String
    }

    /// Signs a request in place. `payload` must be the exact body bytes; pass
    /// nil for streamed uploads and supply `precomputedPayloadHash`.
    ///
    /// `region` and `service` are parameters purely so the implementation can be
    /// checked against AWS's published test vectors, which are all us-east-1.
    static func sign(request: inout URLRequest,
                     payload: Data?,
                     precomputedPayloadHash: String? = nil,
                     credentials: Credentials,
                     date: Date = Date(),
                     region: String = SigV4.region,
                     service: String = SigV4.service) {
        guard let url = request.url, let host = url.host else { return }

        let payloadHash = precomputedPayloadHash ?? hexSHA256(payload ?? Data())
        let amzDate = iso8601Basic(date)
        let dateStamp = String(amzDate.prefix(8))

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let canonical = canonicalise(request: request, url: url, payloadHash: payloadHash)
        let canonicalRequest = canonical.request
        let signedHeaders = canonical.signedHeaders

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hexSHA256(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = derivedSigningKey(
            secret: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = hex(hmac(Data(stringToSign.utf8), key: signingKey))

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Canonicalisation

    /// Builds the canonical request exactly as the AWS specification defines it.
    /// Exposed (internally) because when R2 answers 403 the canonical request is
    /// the only thing worth looking at, and because it is what the published
    /// AWS test vectors pin down.
    static func canonicalise(request: URLRequest,
                             url: URL,
                             payloadHash: String) -> (request: String, signedHeaders: String) {
        let headers = request.allHTTPHeaderFields ?? [:]

        // Header names are lowercased and sorted; values are trimmed and, per
        // the spec, internal runs of whitespace collapse to a single space.
        var normalised: [(name: String, value: String)] = []
        for (key, value) in headers {
            let collapsed = value
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
            normalised.append((key.lowercased(), collapsed))
        }
        normalised.sort { $0.name < $1.name }

        var canonicalHeaders = ""
        var names: [String] = []
        for entry in normalised {
            canonicalHeaders += entry.name + ":" + entry.value + "\n"
            names.append(entry.name)
        }
        let signedHeaders = names.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(url),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        return (canonicalRequest, signedHeaders)
    }

    private static func canonicalURI(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        // Each path segment is encoded, but the separators are not.
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0), encodeSlash: true) }
            .joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else {
            return ""
        }
        var encoded: [(name: String, value: String)] = []
        for item in items {
            let name: String = uriEncode(item.name, encodeSlash: true)
            let value: String = uriEncode(item.value ?? "", encodeSlash: true)
            encoded.append((name, value))
        }
        encoded.sort { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        var pairs: [String] = []
        for entry in encoded {
            pairs.append(entry.name + "=" + entry.value)
        }
        return pairs.joined(separator: "&")
    }

    /// RFC 3986 unreserved set, matching the AWS specification exactly.
    static func uriEncode(_ input: String, encodeSlash: Bool) -> String {
        var output = ""
        for byte in Array(input.utf8) {
            let character = Character(UnicodeScalar(byte))
            if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || character == "-" || character == "_" || character == "." || character == "~" {
                output.append(character)
            } else if character == "/" && !encodeSlash {
                output.append(character)
            } else {
                output.append(String(format: "%%%02X", byte))
            }
        }
        return output
    }

    // MARK: - Crypto

    private static func derivedSigningKey(secret: String,
                                          dateStamp: String,
                                          region: String,
                                          service: String) -> SymmetricKey {
        let initial = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        let dateKey = hmac(Data(dateStamp.utf8), key: initial)
        let regionKey = hmac(Data(region.utf8), key: SymmetricKey(data: dateKey))
        let serviceKey = hmac(Data(service.utf8), key: SymmetricKey(data: regionKey))
        let signingKey = hmac(Data("aws4_request".utf8), key: SymmetricKey(data: serviceKey))
        return SymmetricKey(data: signingKey)
    }

    private static func hmac(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func hexSHA256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hexSHA256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(Data(hasher.finalize()))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601Basic(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
