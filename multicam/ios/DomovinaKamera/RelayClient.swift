import Foundation

/// The control connection to the relay (PROTOCOL.md). It carries commands and
/// status only — recording never depends on it, so a dropped connection mid-take
/// costs nothing but the director's view of this phone.
@MainActor
final class RelayClient: NSObject {

    enum Command {
        case start(sessionId: String, takeId: String)
        case stop(takeId: String)
    }

    var onCommand: ((Command) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// Called on every (re)connect so the owner can send hello + fresh status.
    var onConnected: (() -> Void)?

    /// Relay clock minus this phone's clock, from the round-trip with the smallest RTT.
    private(set) var serverOffsetMs: Double?

    private var config: RelayConfig?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var connected = false
    private var backoff: TimeInterval = 1
    private var reconnectWork: DispatchWorkItem?
    private var timeSamplesLeft = 0
    private var bestRTT = Double.infinity

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func connect(_ config: RelayConfig) {
        self.config = config
        backoff = 1
        open()
    }

    private func open() {
        reconnectWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        guard let config else { return }

        var components = URLComponents(url: config.relay.appendingPathComponent("v1/rooms/\(config.room)/ws"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "role", value: "camera"),
                                 URLQueryItem(name: "id", value: ConfigStore.deviceID),
                                 URLQueryItem(name: "key", value: config.key)]
        guard let url = components.url else { return }

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task)
                case .failure(let error):
                    self.dropped("receive: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }
        switch type {
        case "start":
            guard let sessionId = msg["sessionId"] as? String, let takeId = msg["takeId"] as? String else { return }
            onCommand?(.start(sessionId: sessionId, takeId: takeId))
        case "stop":
            onCommand?(.stop(takeId: msg["takeId"] as? String ?? ""))
        case "time":
            guard let c = msg["c"] as? Double, let s = msg["s"] as? Double else { return }
            let now = Date().timeIntervalSince1970 * 1000
            let rtt = now - c
            if rtt < bestRTT {
                bestRTT = rtt
                serverOffsetMs = s - (c + rtt / 2)
            }
            timeSamplesLeft -= 1
            if timeSamplesLeft > 0 { sendTimeProbe() } else {
                Log.write("time sync: offset \(serverOffsetMs.map { String(format: "%.1f", $0) } ?? "?") ms, rtt \(String(format: "%.1f", bestRTT)) ms")
            }
        default:
            break
        }
    }

    func send(_ message: [String: Any]) {
        guard connected, let task,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, task === self.task else { return }
                self.dropped("send: \(error.localizedDescription)")
            }
        }
    }

    private func sendTimeProbe() {
        send(["type": "time", "c": Date().timeIntervalSince1970 * 1000])
    }

    private func didOpen() {
        connected = true
        backoff = 1
        Log.write("relay connected")
        onConnectionChange?(true)
        onConnected?()
        bestRTT = .infinity
        timeSamplesLeft = 5
        sendTimeProbe()
    }

    private func dropped(_ reason: String) {
        guard task != nil else { return }
        if connected { Log.write("relay dropped: \(reason)") }
        connected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onConnectionChange?(false)
        let delay = backoff
        backoff = min(backoff * 2, 10)
        let work = DispatchWorkItem { [weak self] in self?.open() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension RelayClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard webSocketTask === self.task else { return }
            self.didOpen()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            guard webSocketTask === self.task else { return }
            self.dropped("closed \(closeCode.rawValue)")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            guard task === self.task else { return }
            self.dropped("completed: \(error?.localizedDescription ?? "nil")")
        }
    }
}
