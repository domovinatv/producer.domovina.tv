import Foundation

/// Thin S3-compatible client for Cloudflare R2.
///
/// Two upload paths, chosen by size:
/// * `putObject` — one PUT. Used for every live segment, which we deliberately
///   size to stay well under the limit.
/// * `uploadMultipart` — used for the master files after the take. R2 requires
///   every part except the last to be *exactly* the same size, which is stricter
///   than S3, so the part size is fixed up front rather than adapted mid-upload.
struct R2Client {

    enum ClientError: LocalizedError {
        case notConfigured
        case missingSecret
        case http(Int, String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "R2 nije konfiguriran."
            case .missingSecret: return "R2 secret access key nije u Keychainu."
            case .http(let code, let body):
                return "R2 je vratio HTTP \(code): \(body.prefix(300))"
            case .malformedResponse(let detail): return "Neočekivan odgovor od R2: \(detail)"
            }
        }

        /// Client errors other than throttling will never succeed on retry.
        var isRetryable: Bool {
            switch self {
            case .http(let code, _): return code == 429 || code >= 500
            case .notConfigured, .missingSecret: return false
            case .malformedResponse: return true
            }
        }
    }

    static let multipartPartSize = 16 * 1024 * 1024
    /// Anything larger than this goes through multipart.
    static let singlePutLimit = 64 * 1024 * 1024

    let configuration: R2Configuration
    let credentials: SigV4.Credentials
    let session: URLSession

    init(configuration: R2Configuration, session: URLSession = .shared) throws {
        guard configuration.isUsable else { throw ClientError.notConfigured }
        guard let secret = R2ConfigurationStore.loadSecret(forAccessKeyID: configuration.accessKeyID) else {
            throw ClientError.missingSecret
        }
        self.configuration = configuration
        self.credentials = SigV4.Credentials(accessKeyID: configuration.accessKeyID, secretAccessKey: secret)
        self.session = session
    }

    private func url(forKey key: String, query: [URLQueryItem] = []) throws -> URL {
        guard let endpoint = configuration.endpoint else { throw ClientError.notConfigured }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/" + configuration.bucket + "/" + key
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { SigV4.uriEncode(String($0), encodeSlash: true) }
            .joined(separator: "/")
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw ClientError.notConfigured }
        return url
    }

    // MARK: - Single PUT

    @discardableResult
    func putObject(data: Data, key: String, contentType: String) async throws -> String? {
        var request = URLRequest(url: try url(forKey: key))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        SigV4.sign(request: &request, payload: data, credentials: credentials)

        let (responseData, response) = try await session.upload(for: request, from: data)
        try Self.validate(response: response, data: responseData)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
    }

    @discardableResult
    func putObject(fileURL: URL, key: String, contentType: String) async throws -> String? {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try await putObject(data: data, key: key, contentType: contentType)
    }

    // MARK: - Multipart

    func uploadMultipart(fileURL: URL,
                         key: String,
                         contentType: String,
                         progress: ((Double) -> Void)? = nil) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let totalBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0

        if totalBytes <= Self.singlePutLimit {
            try await putObject(fileURL: fileURL, key: key, contentType: contentType)
            progress?(1)
            return
        }

        let uploadID = try await createMultipartUpload(key: key, contentType: contentType)
        var completedParts: [(number: Int, eTag: String)] = []

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var partNumber = 1
            var bytesSent = 0
            while true {
                guard let chunk = try handle.read(upToCount: Self.multipartPartSize), !chunk.isEmpty else { break }
                let eTag = try await uploadPart(key: key, uploadID: uploadID, partNumber: partNumber, data: chunk)
                completedParts.append((partNumber, eTag))
                bytesSent += chunk.count
                partNumber += 1
                if totalBytes > 0 { progress?(Double(bytesSent) / Double(totalBytes)) }
            }

            try await completeMultipartUpload(key: key, uploadID: uploadID, parts: completedParts)
        } catch {
            try? await abortMultipartUpload(key: key, uploadID: uploadID)
            throw error
        }
    }

    private func createMultipartUpload(key: String, contentType: String) async throws -> String {
        var request = URLRequest(url: try url(forKey: key, query: [URLQueryItem(name: "uploads", value: "")]))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        SigV4.sign(request: &request, payload: Data(), credentials: credentials)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        let body = String(decoding: data, as: UTF8.self)
        guard let uploadID = Self.extract(tag: "UploadId", from: body) else {
            throw ClientError.malformedResponse("nedostaje UploadId")
        }
        return uploadID
    }

    private func uploadPart(key: String, uploadID: String, partNumber: Int, data: Data) async throws -> String {
        let query = [
            URLQueryItem(name: "partNumber", value: String(partNumber)),
            URLQueryItem(name: "uploadId", value: uploadID)
        ]
        var request = URLRequest(url: try url(forKey: key, query: query))
        request.httpMethod = "PUT"
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        SigV4.sign(request: &request, payload: data, credentials: credentials)

        let (responseData, response) = try await session.upload(for: request, from: data)
        try Self.validate(response: response, data: responseData)

        guard let eTag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") else {
            throw ClientError.malformedResponse("dio \(partNumber) nema ETag")
        }
        return eTag
    }

    private func completeMultipartUpload(key: String, uploadID: String, parts: [(number: Int, eTag: String)]) async throws {
        var xml = "<CompleteMultipartUpload>"
        for part in parts {
            xml += "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(part.eTag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let body = Data(xml.utf8)

        var request = URLRequest(url: try url(forKey: key, query: [URLQueryItem(name: "uploadId", value: uploadID)]))
        request.httpMethod = "POST"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        SigV4.sign(request: &request, payload: body, credentials: credentials)

        let (responseData, response) = try await session.upload(for: request, from: body)
        try Self.validate(response: response, data: responseData)

        // S3 can return 200 with an error document; treat that as a failure.
        let text = String(decoding: responseData, as: UTF8.self)
        if text.contains("<Error>") {
            throw ClientError.malformedResponse(Self.extract(tag: "Message", from: text) ?? "greška pri završetku uploada")
        }
    }

    private func abortMultipartUpload(key: String, uploadID: String) async throws {
        var request = URLRequest(url: try url(forKey: key, query: [URLQueryItem(name: "uploadId", value: uploadID)]))
        request.httpMethod = "DELETE"
        SigV4.sign(request: &request, payload: Data(), credentials: credentials)
        _ = try? await session.data(for: request)
    }

    // MARK: - Connectivity check

    /// HEADs the bucket so the user can verify credentials before a take
    /// instead of discovering they are wrong halfway through one.
    func verifyAccess() async throws {
        guard let endpoint = configuration.endpoint else { throw ClientError.notConfigured }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/" + configuration.bucket
        components?.queryItems = [URLQueryItem(name: "max-keys", value: "1")]
        guard let listURL = components?.url else { throw ClientError.notConfigured }

        var request = URLRequest(url: listURL)
        request.httpMethod = "GET"
        SigV4.sign(request: &request, payload: Data(), credentials: credentials)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
    }

    // MARK: - Helpers

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformedResponse("nije HTTP odgovor")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    private static func extract(tag: String, from xml: String) -> String? {
        guard let openRange = xml.range(of: "<\(tag)>"),
              let closeRange = xml.range(of: "</\(tag)>", range: openRange.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[openRange.upperBound..<closeRange.lowerBound])
    }
}
