import Foundation

/// Post: preuzima snimke telefona za jednu sesiju u `<sesija>/cameras/`, gdje ih
/// `finalize_session.sh` sam nađe. Isto što `director.mjs pull`, preko relaya
/// (lista i preuzimanje idu kroz Worker, bez R2 ključeva na ovom Macu).
@MainActor
final class MulticamDownloader: ObservableObject {

    struct RemoteObject: Decodable {
        var key: String
        var size: Int64
        /// `multicam/<sesija>/<kamera>/<datoteka>` → `<kamera>/<datoteka>`
        var relativePath: String { key.split(separator: "/").dropFirst(2).joined(separator: "/") }
    }

    @Published private(set) var remote: [RemoteObject]?
    @Published private(set) var isBusy = false
    @Published private(set) var progress: String?
    @Published private(set) var problem: String?

    private var configuration: MulticamConfiguration { MulticamConfigurationStore.load() }

    /// Što je za sesiju u R2 i koliko toga već ima lokalno.
    func refresh(sessionID: String) async {
        problem = nil
        do {
            remote = try await list(sessionID: sessionID)
        } catch {
            remote = nil
            problem = error.localizedDescription
        }
    }

    func missing(in sessionFolder: URL) -> [RemoteObject] {
        let cameras = sessionFolder.appendingPathComponent("cameras", isDirectory: true)
        return (remote ?? []).filter { object in
            let path = cameras.appendingPathComponent(object.relativePath).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            return size != object.size
        }
    }

    func download(sessionID: String, sessionFolder: URL) async {
        guard !isBusy else { return }
        isBusy = true
        problem = nil
        defer { isBusy = false; progress = nil }
        do {
            remote = try await list(sessionID: sessionID)
            let todo = missing(in: sessionFolder)
            let cameras = sessionFolder.appendingPathComponent("cameras", isDirectory: true)
            for (index, object) in todo.enumerated() {
                progress = String(format: "%d/%d · %@ (%.0f MB)", index + 1, todo.count,
                                  object.relativePath, Double(object.size) / 1_000_000)
                let destination = cameras.appendingPathComponent(object.relativePath)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let (temporary, response) = try await URLSession.shared.download(for: try request(
                    "/v1/object", query: [URLQueryItem(name: "objectKey", value: object.key)]))
                try Self.check(response)
                // Nepotpuna datoteka nikad ne dobije konačno ime: finalize bi je
                // inače uzeo kao kameru i pao usred korelacije.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func list(sessionID: String) async throws -> [RemoteObject] {
        struct Listing: Decodable { var objects: [RemoteObject] }
        let prefix = "multicam/\(MulticamConfiguration.pathSegment(sessionID))/"
        let (data, response) = try await URLSession.shared.data(for: try request(
            "/v1/list", query: [URLQueryItem(name: "prefix", value: prefix)]))
        try Self.check(response)
        return try JSONDecoder().decode(Listing.self, from: data).objects
    }

    private func request(_ path: String, query: [URLQueryItem]) throws -> URLRequest {
        guard let relay = configuration.relay, let key = configuration.key,
              var components = URLComponents(url: relay, resolvingAgainstBaseURL: false) else {
            throw DownloadError.notConfigured
        }
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw DownloadError.notConfigured }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw DownloadError.http(http.statusCode) }
    }

    enum DownloadError: LocalizedError {
        case notConfigured
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Relay za telefone nije podešen (Postavke → Telefoni)."
            case .http(let code): return "Relay je odgovorio HTTP \(code)."
            }
        }
    }
}
