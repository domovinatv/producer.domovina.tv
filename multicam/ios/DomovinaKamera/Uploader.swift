import Foundation
import UIKit

/// One take waiting to reach R2. Persisted after every completed part, so an app
/// relaunch resumes from the next part instead of starting over.
struct PendingUpload: Codable, Equatable {
    var sessionId: String
    var takeId: String
    var camera: String
    var videoFile: String          // file name in Documents
    var sidecarFile: String
    var objectKey: String?
    var uploadId: String?
    var partSize: Int?
    var parts: [Part] = []
    var videoKey: String?
    var sidecarKey: String?

    struct Part: Codable, Equatable {
        var partNumber: Int
        var etag: String
    }
}

/// Uploads takes one at a time, per PROTOCOL.md: multipart for the video (parts read
/// from disk one at a time, never the whole file), a single PUT for the sidecar.
@MainActor
final class Uploader {

    struct Progress { var bytesDone: Int64; var bytesTotal: Int64 }

    var onProgress: ((Progress?) -> Void)?
    var onUploaded: ((PendingUpload) -> Void)?
    var onError: ((String?) -> Void)?

    private var queue: [PendingUpload]
    private var running = false
    private var config: RelayConfig?
    private let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pending-uploads.json")
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        queue = (try? JSONDecoder().decode([PendingUpload].self, from: Data(contentsOf: storeURL))) ?? []
    }

    var pendingCount: Int { queue.count }

    func setConfig(_ config: RelayConfig) {
        self.config = config
        kick()
    }

    func enqueue(_ upload: PendingUpload) {
        queue.append(upload)
        persist()
        kick()
    }

    func kick() {
        guard !running, config != nil, !queue.isEmpty else { return }
        running = true
        Task { await self.drain() }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(queue).write(to: storeURL, options: .atomic)
    }

    private func drain() async {
        // A short trip out of the app must not kill an upload halfway through a part.
        let background = UIApplication.shared.beginBackgroundTask(withName: "upload")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            running = false
        }
        while let config, var item = queue.first {
            do {
                try await upload(&item, config: config)
                queue.removeFirst()
                persist()
                onProgress?(nil)
                onError?(nil)
                onUploaded?(item)
            } catch {
                Log.write("upload \(item.takeId) failed: \(error)")
                onError?("Upload: \(error.localizedDescription)")
                onProgress?(nil)
                // Leave it queued; retry later rather than spinning.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.kick() }
                return
            }
        }
    }

    private func save(_ item: PendingUpload) {
        if let i = queue.firstIndex(where: { $0.takeId == item.takeId && $0.sessionId == item.sessionId }) {
            queue[i] = item
            persist()
        }
    }

    private func upload(_ item: inout PendingUpload, config: RelayConfig) async throws {
        let videoURL = documents.appendingPathComponent(item.videoFile)
        let size = try (FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        if item.videoKey == nil {
            if item.uploadId == nil {
                let body: [String: Any] = ["sessionId": item.sessionId, "camera": item.camera, "file": item.videoFile]
                let created = try await request(config, "POST", "v1/upload/create", body: try JSONSerialization.data(withJSONObject: body))
                item.objectKey = created["objectKey"] as? String
                item.uploadId = created["uploadId"] as? String
                item.partSize = created["partSize"] as? Int
                item.parts = []
                guard item.objectKey != nil, item.uploadId != nil, item.partSize != nil else { throw UploadError.badResponse }
                save(item)
            }
            let partSize = Int64(item.partSize!)
            let partCount = Int((size + partSize - 1) / partSize)
            let handle = try FileHandle(forReadingFrom: videoURL)
            defer { try? handle.close() }

            for number in 1...max(partCount, 1) where !item.parts.contains(where: { $0.partNumber == number }) {
                onProgress?(Progress(bytesDone: min(size, Int64(item.parts.count) * partSize), bytesTotal: size))
                try handle.seek(toOffset: UInt64(Int64(number - 1) * partSize))
                let chunk = try handle.read(upToCount: Int(partSize)) ?? Data()
                let query = [URLQueryItem(name: "objectKey", value: item.objectKey),
                             URLQueryItem(name: "uploadId", value: item.uploadId),
                             URLQueryItem(name: "part", value: String(number))]
                let result = try await withRetry { try await self.request(config, "PUT", "v1/upload/part", query: query, body: chunk) }
                guard let etag = result["etag"] as? String else { throw UploadError.badResponse }
                item.parts.append(.init(partNumber: number, etag: etag))
                save(item)
            }
            onProgress?(Progress(bytesDone: size, bytesTotal: size))

            let parts = item.parts.sorted { $0.partNumber < $1.partNumber }.map { ["partNumber": $0.partNumber, "etag": $0.etag] }
            let body: [String: Any] = ["objectKey": item.objectKey!, "uploadId": item.uploadId!, "parts": parts]
            let done = try await withRetry {
                try await self.request(config, "POST", "v1/upload/complete", body: try JSONSerialization.data(withJSONObject: body))
            }
            let uploadedSize = (done["size"] as? NSNumber)?.int64Value
            guard uploadedSize == size else { throw UploadError.sizeMismatch(uploadedSize ?? -1, size) }
            item.videoKey = done["objectKey"] as? String ?? item.objectKey
            save(item)
        }

        if item.sidecarKey == nil {
            let data = try Data(contentsOf: documents.appendingPathComponent(item.sidecarFile))
            let query = [URLQueryItem(name: "sessionId", value: item.sessionId),
                         URLQueryItem(name: "camera", value: item.camera),
                         URLQueryItem(name: "file", value: item.sidecarFile)]
            let result = try await withRetry { try await self.request(config, "PUT", "v1/object", query: query, body: data) }
            item.sidecarKey = result["objectKey"] as? String
            save(item)
        }
        Log.write("uploaded \(item.takeId): \(item.videoKey ?? "?") (\(size) B), \(item.sidecarKey ?? "?")")
    }

    private func withRetry(_ op: @escaping () async throws -> [String: Any]) async throws -> [String: Any] {
        var delay: UInt64 = 1
        for attempt in 1...5 {
            do { return try await op() } catch {
                if attempt == 5 { throw error }
                Log.write("retry \(attempt): \(error)")
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay *= 2
            }
        }
        throw UploadError.badResponse
    }

    private func request(_ config: RelayConfig, _ method: String, _ path: String,
                         query: [URLQueryItem] = [], body: Data? = nil) async throws -> [String: Any] {
        var components = URLComponents(url: config.relay.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.timeoutInterval = 300
        req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.upload(for: req, from: body ?? Data())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw UploadError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    enum UploadError: LocalizedError {
        case badResponse
        case http(Int, String)
        case sizeMismatch(Int64, Int64)

        var errorDescription: String? {
            switch self {
            case .badResponse: return "neočekivan odgovor relaya"
            case .http(let code, let body): return "HTTP \(code) \(body.prefix(120))"
            case .sizeMismatch(let got, let want): return "veličina \(got) ≠ \(want)"
            }
        }
    }
}
