import Foundation

/// Durable, crash-tolerant upload queue.
///
/// Every item is on disk before it is enqueued, and the queue itself is
/// journalled next to the recording. If the app dies mid-take, relaunching and
/// pointing at the session folder resumes exactly where it stopped.
///
/// The queue never blocks capture: enqueue is fire-and-forget, and a saturated
/// or offline link only grows the backlog, which the UI surfaces as a number
/// rather than a stall.
actor UploadQueue {

    enum ItemKind: String, Codable {
        case audioSegment
        case videoSegment
        case manifest
        case master
    }

    enum ItemState: String, Codable {
        case pending
        case uploading
        case done
        case failed
    }

    struct Item: Codable, Identifiable {
        var id: String
        var kind: ItemKind
        var localPath: String
        var remoteKey: String
        var contentType: String
        var byteCount: Int
        var state: ItemState = .pending
        var attempts: Int = 0
        var lastError: String?
        var deleteLocalAfterUpload: Bool
        var enqueuedAt: Date = Date()
        var completedAt: Date?
    }

    struct Stats: Sendable, Equatable {
        var pending = 0
        var uploading = 0
        var done = 0
        var failed = 0
        var pendingBytes = 0
        var uploadedBytes = 0
        var lastError: String?
        var isPaused = false
        var isConfigured = false

        var backlogDescription: String {
            if !isConfigured { return "R2 isključen" }
            if failed > 0 { return "\(failed) neuspješno · \(pending) u redu" }
            if pending == 0 && uploading == 0 { return "sve poslano" }
            return "\(pending + uploading) u redu · \(ByteCountFormatter.string(fromByteCount: Int64(pendingBytes), countStyle: .file))"
        }
    }

    private let journalURL: URL
    private var items: [Item] = []
    private var client: R2Client?
    private var stats = Stats()
    private var isPumping = false
    private var isPaused = false
    private let maxConcurrent = 2
    private let maxAttempts = 8

    init(journalURL: URL, configuration: R2Configuration) {
        self.journalURL = journalURL
        if configuration.isUsable {
            self.client = try? R2Client(configuration: configuration)
            self.stats.isConfigured = self.client != nil
        }
        // Inlined rather than calling loadJournal(): an actor's isolated
        // methods are not reachable from a synchronous init.
        if let data = try? Data(contentsOf: journalURL),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            // Anything caught mid-flight by a crash goes back in the queue.
            items = decoded.map { item in
                var copy = item
                if copy.state == .uploading { copy.state = .pending }
                return copy
            }
        }
    }

    func currentStats() -> Stats {
        var snapshot = stats
        snapshot.pending = items.filter { $0.state == .pending }.count
        snapshot.uploading = items.filter { $0.state == .uploading }.count
        snapshot.done = items.filter { $0.state == .done }.count
        snapshot.failed = items.filter { $0.state == .failed }.count
        snapshot.pendingBytes = items.filter { $0.state == .pending || $0.state == .uploading }
            .reduce(0) { $0 + $1.byteCount }
        snapshot.isPaused = isPaused
        return snapshot
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { pump() }
    }

    /// Re-queues everything that gave up. Useful after the Wi-Fi comes back.
    func retryFailed() {
        for index in items.indices where items[index].state == .failed {
            items[index].state = .pending
            items[index].attempts = 0
        }
        saveJournal()
        pump()
    }

    // MARK: - Enqueue

    func enqueue(fileURL: URL,
                 remoteKey: String,
                 kind: ItemKind,
                 contentType: String,
                 deleteLocalAfterUpload: Bool) {
        guard client != nil else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)??.intValue ?? 0
        items.append(
            Item(
                id: UUID().uuidString,
                kind: kind,
                localPath: fileURL.path,
                remoteKey: remoteKey,
                contentType: contentType,
                byteCount: size,
                deleteLocalAfterUpload: deleteLocalAfterUpload
            )
        )
        saveJournal()
        pump()
    }

    /// Writes in-memory data (the fMP4 chunks from AVAssetWriter) to disk first,
    /// so nothing lives only in RAM while waiting for the network.
    func enqueue(data: Data,
                 stagingURL: URL,
                 remoteKey: String,
                 kind: ItemKind,
                 contentType: String,
                 deleteLocalAfterUpload: Bool) {
        guard client != nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stagingURL, options: .atomic)
        } catch {
            stats.lastError = "Ne mogu spremiti segment na disk: \(error.localizedDescription)"
            return
        }
        enqueue(
            fileURL: stagingURL,
            remoteKey: remoteKey,
            kind: kind,
            contentType: contentType,
            deleteLocalAfterUpload: deleteLocalAfterUpload
        )
    }

    // MARK: - Pump

    private func pump() {
        guard !isPumping, !isPaused, client != nil else { return }
        isPumping = true
        Task { await self.drain() }
    }

    private func drain() async {
        defer { isPumping = false }

        while !isPaused {
            let batch = nextBatch()
            guard !batch.isEmpty else { break }

            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask { await self.upload(itemID: item.id) }
                }
            }
        }
    }

    private func nextBatch() -> [Item] {
        let inFlight = items.filter { $0.state == .uploading }.count
        let slots = max(0, maxConcurrent - inFlight)
        guard slots > 0 else { return [] }

        var batch: [Item] = []
        for index in items.indices where items[index].state == .pending {
            items[index].state = .uploading
            batch.append(items[index])
            if batch.count >= slots { break }
        }
        return batch
    }

    private func upload(itemID: String) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }), let client else { return }
        let item = items[index]
        let fileURL = URL(fileURLWithPath: item.localPath)

        guard FileManager.default.fileExists(atPath: item.localPath) else {
            markFailed(itemID: itemID, error: "lokalna datoteka je nestala", retryable: false)
            return
        }

        do {
            if item.byteCount > R2Client.singlePutLimit {
                try await client.uploadMultipart(fileURL: fileURL, key: item.remoteKey, contentType: item.contentType)
            } else {
                try await client.putObject(fileURL: fileURL, key: item.remoteKey, contentType: item.contentType)
            }
            markDone(itemID: itemID, deleteLocal: item.deleteLocalAfterUpload, fileURL: fileURL)
        } catch {
            let retryable = (error as? R2Client.ClientError)?.isRetryable ?? true
            markFailed(itemID: itemID, error: error.localizedDescription, retryable: retryable)

            if retryable, let current = items.first(where: { $0.id == itemID }), current.state == .pending {
                // Exponential backoff, capped so a long outage still retries
                // every couple of minutes rather than drifting to hours.
                let delay = min(120.0, pow(2.0, Double(min(current.attempts, 7))))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func markDone(itemID: String, deleteLocal: Bool, fileURL: URL) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].state = .done
        items[index].completedAt = Date()
        items[index].lastError = nil
        stats.uploadedBytes += items[index].byteCount
        if deleteLocal {
            try? FileManager.default.removeItem(at: fileURL)
        }
        saveJournal()
    }

    private func markFailed(itemID: String, error: String, retryable: Bool) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].attempts += 1
        items[index].lastError = error
        items[index].state = (retryable && items[index].attempts < maxAttempts) ? .pending : .failed
        stats.lastError = error
        saveJournal()
    }

    // MARK: - Journal

    private func saveJournal() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: journalURL, options: .atomic)
    }

    /// Waits for the queue to empty, so "stop recording" can report an honest
    /// "everything is off-site" instead of a hopeful one.
    func waitUntilDrained(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = currentStats()
            if snapshot.pending == 0 && snapshot.uploading == 0 { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
