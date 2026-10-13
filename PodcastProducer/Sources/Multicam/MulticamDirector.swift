import Foundation

/// Studio kao režija za telefone-kamere: drži WebSocket prema relayu kao
/// `director.mjs watch`, prikazuje tko je spojen i šalje start/stop zajedno sa
/// snimanjem u Studiju.
///
/// Pravilo kao i za R2: relay nikad ne smije zaustaviti ni odgoditi snimanje.
/// Ako veze nema kad se pritisne Snimaj, naredba čeka i šalje se čim se veza
/// vrati; telefon koji se spoji usred takea relay sam pokrene.
@MainActor
final class MulticamDirector: ObservableObject {

    struct Camera: Decodable, Identifiable, Equatable {
        struct Status: Decodable, Equatable {
            struct Upload: Decodable, Equatable {
                var bytesDone: Double
                var bytesTotal: Double
            }
            var state: String?
            var takeId: String?
            var recordingSeconds: Double?
            var battery: Double?
            var charging: Bool?
            var freeBytes: Double?
            var upload: Upload?
            var error: String?
        }
        var id: String
        var name: String?
        var platform: String?
        var model: String?
        var status: Status?

        var displayName: String { name ?? model ?? String(id.prefix(8)) }
    }

    struct Take: Decodable, Equatable {
        var sessionId: String
        var takeId: String
    }

    enum Connection: Equatable {
        case off
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var cameras: [Camera] = []
    @Published private(set) var take: Take?
    @Published private(set) var configuration = MulticamConfigurationStore.load()

    /// Događaji s telefona (start, stop, upload) za dnevnik sesije.
    var onEvent: ((String, SessionManifest.Event.Level) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var backoff: Double = 1
    private var pending: [String: String]?
    private var pingTimer: Timer?
    private let session = URLSession(configuration: .default)
    private let clientID = UUID().uuidString

    init() {
        if configuration.isUsable { connect() }
    }

    func update(_ newConfiguration: MulticamConfiguration) {
        MulticamConfigurationStore.save(newConfiguration)
        configuration = newConfiguration
        disconnect()
        if newConfiguration.isUsable { connect() }
    }

    var isActive: Bool { configuration.isUsable }

    // MARK: - Naredbe

    /// takeId = sessionId: Studio ima jedan take po sesiji, a relay i telefoni
    /// po takeId-u prepoznaju ponovljeni start kao isti.
    func start(sessionID: String) {
        guard isActive else { return }
        send(["type": "start", "sessionId": sessionID, "takeId": sessionID])
        let online = cameras.count
        onEvent?(online == 0
                 ? "Multicam: start poslan, ali nijedan telefon nije spojen"
                 : "Multicam: start poslan na \(online) \(online == 1 ? "telefon" : "telefona")",
                 online == 0 ? .warning : .info)
    }

    func stop(sessionID: String) {
        guard isActive else { return }
        send(["type": "stop", "takeId": sessionID])
        onEvent?("Multicam: stop poslan — telefoni sad šalju snimke", .info)
    }

    private func send(_ message: [String: String]) {
        guard connection == .connected, let task,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            // Zadnja naredba pobjeđuje: stop poslije neisporučenog starta je i dalje
            // ispravan (relay i telefoni ga ignoriraju ako ništa ne snima).
            pending = message
            return
        }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.pending = message
                self?.reconnect(after: error.localizedDescription)
            }
        }
    }

    // MARK: - Veza

    func connect() {
        guard let relay = configuration.relay, let key = configuration.key, task == nil else { return }
        var components = URLComponents(url: relay, resolvingAgainstBaseURL: false)
        components?.scheme = relay.scheme == "http" ? "ws" : "wss"
        components?.path = "/v1/rooms/\(configuration.room)/ws"
        components?.queryItems = [
            URLQueryItem(name: "role", value: "director"),
            URLQueryItem(name: "id", value: "studio-\(clientID)"),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components?.url else {
            connection = .failed("Neispravan URL relaya")
            return
        }
        generation += 1
        let current = generation
        connection = .connecting
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        receive(on: newTask, generation: current)

        // Ping potvrđuje vezu (prvi uspjeh = spojeni) i otkriva tiho mrtvu vezu
        // nakon promjene mreže, koju URLSession inače ne javi.
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ping(generation: current) }
        }
        ping(generation: current)
    }

    func disconnect() {
        generation += 1
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connection = .off
        cameras = []
        take = nil
    }

    private func ping(generation current: Int) {
        guard current == generation, let task else { return }
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                if let error {
                    self.reconnect(after: error.localizedDescription)
                } else if self.connection != .connected {
                    self.didConnect()
                }
            }
        }
    }

    private func didConnect() {
        connection = .connected
        backoff = 1
        if let message = pending {
            pending = nil
            send(message)
        }
    }

    private func reconnect(after reason: String) {
        guard task != nil else { return }
        generation += 1
        pingTimer?.invalidate()
        task?.cancel()
        task = nil
        cameras = []
        connection = .failed(reason)
        let delay = backoff
        backoff = min(backoff * 2, 10)
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self, current == self.generation, self.configuration.isUsable else { return }
                self.connect()
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask, generation current: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.reconnect(after: error.localizedDescription)
                case .success(let message):
                    if self.connection != .connected { self.didConnect() }
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task, generation: current)
                }
            }
        }
    }

    // MARK: - Poruke relaya

    private struct Envelope: Decodable {
        var type: String
        var cameras: [Camera]?
        var take: Take?
        var cameraName: String?
        var objectKeys: [String]?
        var durationSeconds: Double?
        var bytes: Double?
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        let who = message.cameraName ?? "telefon"
        switch message.type {
        case "cameras":
            cameras = (message.cameras ?? []).sorted { $0.displayName < $1.displayName }
            take = message.take
        case "recordingStarted":
            onEvent?("📱 \(who): snima", .info)
        case "recordingStopped":
            let size = (message.bytes ?? 0) / 1_000_000
            onEvent?(String(format: "📱 %@: zaustavljen (%.0f s, %.0f MB), šalje", who, message.durationSeconds ?? 0, size), .info)
        case "uploaded":
            onEvent?("📱 \(who): snimka je u R2", .info)
        default:
            break
        }
    }
}
