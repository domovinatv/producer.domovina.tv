import Foundation

/// The control connection to the relay (PROTOCOL.md). It carries commands and
/// status only — recording never depends on it, so a dropped connection mid-take
/// costs nothing but the director's view of this phone.
@MainActor
final class RelayClient: NSObject {

    enum Command {
        case start(sessionId: String, takeId: String, startAtServerMs: Double?)
        case stop(takeId: String)
        /// The relay's current take (nil = none), sent on every connect.
        case state(takeId: String?)
    }

    var onCommand: ((Command) -> Void)?
    /// Every `time` reply, on the host clock (PROTOCOL.md "Sat").
    var onClockSample: ((ClockSample) -> Void)?
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
    /// Probes in flight: `c` (wall ms, echoed by the relay) → host ns at send.
    private var probes: [Int64: (t1: Int64, wallMs: Double)] = [:]
    private var timeTimer: Timer?
    private var burstRTTs: [Double] = []

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
            // Arrival time before any hop, so main-thread work does not inflate RTT.
            let t4 = HostClock.nowNs()
            Task { @MainActor in
                guard let self, task === self.task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text, receivedNs: t4) }
                    self.receive(on: task)
                case .failure(let error):
                    self.dropped("receive: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ text: String, receivedNs t4: Int64) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }
        switch type {
        case "start":
            guard let sessionId = msg["sessionId"] as? String, let takeId = msg["takeId"] as? String else { return }
            onCommand?(.start(sessionId: sessionId, takeId: takeId,
                              startAtServerMs: (msg["startAtServerMs"] as? NSNumber)?.doubleValue))
        case "stop":
            onCommand?(.stop(takeId: msg["takeId"] as? String ?? ""))
        case "state":
            let take = msg["take"] as? [String: Any]
            onCommand?(.state(takeId: take?["takeId"] as? String))
        case "time":
            guard let c = (msg["c"] as? NSNumber)?.int64Value, let s = (msg["s"] as? NSNumber)?.int64Value,
                  let probe = probes.removeValue(forKey: c) else { return }
            let sample = ClockSample(t1: probe.t1, t4: t4, s: s)
            onClockSample?(sample)
            // Wall-clock offset for the v1 `serverOffsetMs` field.
            let rtt = Double(sample.rttNs) / 1e6
            if rtt < bestRTT {
                bestRTT = rtt
                serverOffsetMs = Double(s) - (probe.wallMs + rtt / 2)
            }
            if timeSamplesLeft > 0 {
                burstRTTs.append(rtt)
                timeSamplesLeft -= 1
                if timeSamplesLeft > 0 { sendTimeProbe() } else {
                    Log.write("time sync: offset \(serverOffsetMs.map { String(format: "%.1f", $0) } ?? "?") ms, burst rtt \(burstRTTs.map { String(format: "%.0f", $0) }.joined(separator: "/")) ms, then every 5 s")
                }
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
        guard connected else { return }
        let wallMs = Date().timeIntervalSince1970 * 1000
        var c = Int64(wallMs)
        while probes[c] != nil { c += 1 }
        // A probe whose reply never came (socket died) is forgotten after a minute.
        let t1 = HostClock.nowNs()
        probes = probes.filter { t1 - $0.value.t1 < ClockMath.minute }
        probes[c] = (t1, wallMs)
        send(["type": "time", "c": c])
    }

    private func didOpen() {
        connected = true
        backoff = 1
        Log.write("relay connected")
        onConnectionChange?(true)
        onConnected?()
        bestRTT = .infinity
        probes = [:]
        burstRTTs = []
        timeSamplesLeft = 5
        sendTimeProbe()
        // Keep sampling for as long as the socket lives, not just at connect: post
        // fits offset and drift through the minimum-RTT samples around each take.
        timeTimer?.invalidate()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connected else { return }
                // A burst probe whose reply was lost must not stall sampling.
                self.timeSamplesLeft = 0
                self.sendTimeProbe()
            }
        }
    }

    private func dropped(_ reason: String) {
        guard task != nil else { return }
        if connected { Log.write("relay dropped: \(reason)") }
        connected = false
        timeTimer?.invalidate()
        timeTimer = nil
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
