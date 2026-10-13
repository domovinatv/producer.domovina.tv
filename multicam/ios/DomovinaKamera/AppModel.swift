import AVFoundation
import UIKit

/// Ties the camera, the relay connection and the uploader together, and owns the
/// take state machine (decisions in `TakeRules`). `start` and `stop` are idempotent,
/// as PROTOCOL.md requires: the relay re-sends `start` to every camera that
/// (re)connects during a take. Losing the relay never stops a recording; only a
/// `stop`, or a `state` saying the take is over, does.
@MainActor
final class AppModel: ObservableObject {

    enum State: String { case idle, recording, uploading, error }

    struct Take: Equatable {
        var sessionId: String
        var takeId: String
        /// false for a take started with the button on the phone.
        var fromRelay: Bool
        var startAtServerMs: Double?
    }

    @Published private(set) var config: RelayConfig?
    @Published private(set) var connected = false
    @Published private(set) var cameraReady = false
    @Published private(set) var recordingSince: Date?
    /// Armed (waiting for its scheduled start) or recording.
    @Published private(set) var currentTake: Take?
    @Published private(set) var upload: Uploader.Progress?
    @Published private(set) var lastError: String?
    @Published var scanning = false {
        didSet { camera.setScanning(scanning) }
    }

    let camera = CameraController()
    let clockLog = ClockLog(url: ClockLog.defaultURL)
    private let relay = RelayClient()
    private let uploader = Uploader()
    private var statusTimer: Timer?
    private var pendingStart: Take?
    private var stopping = false
    private var sessionRunning = false
    private var started: CameraController.StartInfo?
    private var finishTask: UIBackgroundTaskIdentifier = .invalid
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// takeIds already recorded here, so a re-sent `start` for a take that ended
    /// early (interruption) does not overwrite its file while it waits for upload.
    private var finishedTakes: [String] = UserDefaults.standard.stringArray(forKey: "finishedTakes") ?? [] {
        didSet { UserDefaults.standard.set(Array(finishedTakes.suffix(200)), forKey: "finishedTakes") }
    }

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        config = ConfigStore.load()

        relay.onConnectionChange = { [weak self] in self?.connected = $0 }
        relay.onConnected = { [weak self] in self?.sendHello() }
        relay.onCommand = { [weak self] in self?.handle($0) }
        relay.onClockSample = { [weak self] in self?.clockLog.append($0) }

        uploader.onProgress = { [weak self] in self?.upload = $0; self?.sendStatus() }
        uploader.onError = { [weak self] in self?.lastError = $0; self?.sendStatus() }
        uploader.onUploaded = { [weak self] item in
            self?.relay.send(["type": "uploaded", "sessionId": item.sessionId, "takeId": item.takeId,
                              "objectKeys": [item.videoKey, item.sidecarKey].compactMap { $0 }])
            self?.sendStatus()
        }
        // Right before the sidecar goes up, add every clock sample taken since the
        // take ended: PROTOCOL.md wants them "until the end of the upload".
        let clockLog = self.clockLog
        uploader.beforeSidecarUpload = { item, url in
            guard let offset = item.clockOffsetMs else { return }
            let count = Sidecar.refreshClockSamples(at: url, log: clockLog, offsetMs: offset)
            Log.write("sidecar \(item.takeId): \(count) clock samples")
        }

        camera.onRecordingStarted = { [weak self] in self?.recordingStarted($0) }
        camera.onRecordingFinished = { [weak self] url, error in self?.recordingFinished(url, error) }
        camera.onInterrupted = { [weak self] reason in
            guard let self, self.currentTake != nil else { return }
            Log.write("camera interrupted (\(reason)): finishing the file")
            self.stop()
        }
        camera.onQRCode = { [weak self] value in
            guard let self, self.scanning, let url = URL(string: value) else { return }
            if self.apply(joinURL: url) { self.scanning = false }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentTake != nil else { return }
                // iOS takes the camera away in the background; close the file
                // properly instead of leaving it to the interruption.
                Log.write("background: finishing the file")
                self.stop()
            }
        }

        if let config {
            relay.connect(config)
            uploader.setConfig(config)
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendStatus() }
        }
        Log.write("launch \(DeviceInfo.modelIdentifier) iOS \(DeviceInfo.osVersion) app \(DeviceInfo.appVersion), pending uploads \(uploader.pendingCount), clock samples on disk \(clockLog.count()), boot \(clockLog.bootID)")
    }

    func prepareCamera() {
        // The permission prompt waits for a tap on the phone; tell the director why
        // this camera is not ready instead of looking idle.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
            || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            lastError = "Čeka dozvolu za kameru i mikrofon na telefonu"
            Log.write("camera: waiting for permission")
            sendStatus()
        }
        camera.prepare { [weak self] error in
            guard let self else { return }
            if let error {
                self.lastError = error
                Log.write("camera: \(error)")
                self.sendStatus()
                return
            }
            self.cameraReady = true
            self.lastError = nil
            self.sendStatus()
        }
    }

    /// Called by the preview once its layer holds the session.
    func previewAttached() {
        camera.startRunning { [weak self] in
            guard let self else { return }
            self.sessionRunning = true
            if let pending = self.pendingStart {
                self.pendingStart = nil
                // Give the session a moment to deliver frames before recording.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start(pending) }
            }
        }
    }

    @discardableResult
    func apply(joinURL url: URL) -> Bool {
        guard let new = RelayConfig(joinURL: url, fallbackName: config?.name ?? ConfigStore.defaultName) else { return false }
        Log.write("join room \(new.room) as \(new.name)")
        ConfigStore.save(new)
        config = new
        relay.connect(new)
        uploader.setConfig(new)
        return true
    }

    func rename(_ name: String) {
        guard var config, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        config.name = name.trimmingCharacters(in: .whitespaces)
        ConfigStore.save(config)
        self.config = config
        sendHello()
    }

    // MARK: - Takes

    var state: State {
        if recordingSince != nil || currentTake != nil { return .recording }
        if upload != nil { return .uploading }
        if lastError != nil && !cameraReady { return .error }
        return .idle
    }

    func toggleManualRecording() {
        if currentTake != nil {
            stop()
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let sid = "local-\(formatter.string(from: Date()))"
            start(Take(sessionId: sid, takeId: sid, fromRelay: false, startAtServerMs: nil))
        }
    }

    private func handle(_ command: RelayClient.Command) {
        switch command {
        case .start(let sessionId, let takeId, let at):
            start(Take(sessionId: sessionId, takeId: takeId, fromRelay: true, startAtServerMs: at))
        case .stop(let takeId):
            guard TakeRules.stopApplies(takeId: takeId, current: currentTake?.takeId, pending: pendingStart?.takeId) else {
                Log.write("stop \(takeId) ignored: not this take")
                return
            }
            stop()
        case .state(let takeId):
            let decision = TakeRules.onState(
                relayTakeId: takeId,
                current: currentTake.map { .init(takeId: $0.takeId, fromRelay: $0.fromRelay) },
                pending: pendingStart.map { .init(takeId: $0.takeId, fromRelay: $0.fromRelay) })
            Log.write("state: relay take \(takeId ?? "none")")
            if decision.cancelPending, let pending = pendingStart {
                Log.write("state: deferred take \(pending.takeId) cancelled")
                pendingStart = nil
                sendStatus()
            }
            if decision.stopCurrent, let current = currentTake {
                Log.write("state: take \(current.takeId) ended while offline, stopping")
                stop()
            }
        }
    }

    private func start(_ take: Take) {
        switch TakeRules.onStart(takeId: take.takeId, current: currentTake?.takeId, pending: pendingStart?.takeId,
                                 finished: Set(finishedTakes), stopping: stopping, cameraRunning: sessionRunning) {
        case .ignoreDuplicate:
            if pendingStart?.takeId == take.takeId { pendingStart = take }
            return
        case .ignoreFinished:
            Log.write("start \(take.takeId) ignored: already recorded on this phone")
            return
        case .replaceCurrent:
            // A different take while one is running: finish the old one first.
            pendingStart = take
            stop()
            return
        case .deferUntilCameraReady:
            pendingStart = take
            Log.write("start \(take.takeId) deferred: camera not ready")
            sendStatus()
            return
        case .startNow:
            break
        }
        currentTake = take
        lastError = nil
        let url = documents.appendingPathComponent(Self.fileName(take.takeId))
        let atNs = scheduledHostNs(take)
        camera.startRecording(to: url, atHostNs: atNs)
        sendStatus()
    }

    /// Host-clock instant at which the relay's `startAtServerMs` falls, by the
    /// minimum-RTT recent clock sample; now if it has passed or nothing is known.
    private func scheduledHostNs(_ take: Take) -> Int64 {
        let now = HostClock.nowNs()
        guard let at = take.startAtServerMs else {
            Log.write("start \(take.sessionId)/\(take.takeId) now")
            return now
        }
        let (ns, basis) = ClockMath.startHostNs(startAtServerMs: at, nowNs: now, samples: clockLog.recentSamples())
        if let basis {
            Log.write(String(format: "start %@/%@ at server %.0f: in %.1f ms (offset %.1f ms, rtt %.1f ms, sample age %.0f s)",
                             take.sessionId, take.takeId, at, Double(ns - now) / 1e6, basis.offsetMs,
                             Double(basis.rttNs) / 1e6, Double(now - basis.t4) / 1e9))
            return ns
        }
        if let offset = relay.serverOffsetMs {
            let delayMs = at - (Date().timeIntervalSince1970 * 1000 + offset)
            Log.write(String(format: "start %@ at server %.0f: in %.1f ms (wall clock fallback)", take.takeId, at, delayMs))
            return now + Int64(max(0, delayMs) * 1e6)
        }
        Log.write("start \(take.takeId): no clock sample, starting now")
        return now
    }

    private func stop() {
        // A start still waiting for the camera is cancelled by a stop, too.
        if currentTake == nil, let pending = pendingStart {
            Log.write("stop: deferred take \(pending.takeId) cancelled")
            pendingStart = nil
            sendStatus()
        }
        guard currentTake != nil, !stopping else { return }
        stopping = true
        Log.write("stop \(currentTake?.takeId ?? "")")
        // Finishing the file must survive a trip to the background.
        if finishTask == .invalid {
            finishTask = UIApplication.shared.beginBackgroundTask(withName: "finish-take")
        }
        camera.stopRecording()
    }

    private static func fileName(_ takeId: String) -> String {
        "take-\(safe(takeId)).mov"
    }

    private static func safe(_ takeId: String) -> String {
        takeId.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    }

    private func recordingStarted(_ info: CameraController.StartInfo) {
        recordingSince = info.wallClock
        started = info
        guard let take = currentTake else { return }
        Log.write("recording \(take.takeId): fileZero \(info.fileZeroDeviceNs) ns, wall \(Int64(info.wallClock.timeIntervalSince1970 * 1000))")
        relay.send(["type": "recordingStarted", "sessionId": take.sessionId, "takeId": take.takeId,
                    "file": info.url.lastPathComponent, "wallClockMs": (info.wallClock.timeIntervalSince1970 * 1000).rounded()])
        sendStatus()
    }

    private func recordingFinished(_ url: URL?, _ error: Error?) {
        let take = currentTake
        let info = started
        let wasStopped = stopping
        recordingSince = nil
        currentTake = nil
        started = nil
        stopping = false
        if case TakeWriter.WriterError.notStarted? = error, wasStopped {
            Log.write("take \(take?.takeId ?? "?") stopped before its first frame")
        } else if let error {
            lastError = (error as? TakeWriter.WriterError)?.errorDescription ?? "Snimka: \(error.localizedDescription)"
            Log.write("recording \(take?.takeId ?? "?") ended: \(error)")
        }
        sendStatus()
        if let take, let url, let info, FileManager.default.fileExists(atPath: url.path) {
            finishedTakes.append(take.takeId)
            Task { await self.finalize(url, take: take, info: info) }
        }
        if finishTask != .invalid {
            UIApplication.shared.endBackgroundTask(finishTask)
            finishTask = .invalid
        }
        if let next = pendingStart {
            pendingStart = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start(next) }
        }
    }

    private func finalize(_ url: URL, take: Take, info: CameraController.StartInfo) async {
        let sidecarName = "\(Self.safe(take.takeId)).json"
        // This boot's relay−host offset, to pick this boot's samples now and at upload.
        let offsetMs = ClockMath.bestSample(clockLog.recentSamples(), nowNs: HostClock.nowNs())?.offsetMs
        let samples = offsetMs.map { clockLog.samples(offsetMs: $0, fromNs: info.fileZeroDeviceNs - Sidecar.samplesBeforeNs) } ?? []
        let clock = Sidecar.Clock(fileZeroDeviceNs: info.fileZeroDeviceNs, method: info.method,
                                  uncertaintyMs: info.uncertaintyMs, samples: samples)
        let sidecar = await Sidecar.make(for: url, sessionId: take.sessionId, takeId: take.takeId,
                                         cameraName: config?.name ?? ConfigStore.defaultName,
                                         startWallClock: info.wallClock, serverOffsetMs: relay.serverOffsetMs, clock: clock)
        do {
            let data = try JSONSerialization.data(withJSONObject: sidecar.json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: documents.appendingPathComponent(sidecarName))
        } catch {
            lastError = "Sidecar: \(error.localizedDescription)"
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        Log.write("finished \(take.takeId): \(bytes) B, \(String(format: "%.2f", sidecar.duration)) s, \(clock.samples.count) clock samples so far\(sidecar.firstFrameNote)")
        relay.send(["type": "recordingStopped", "sessionId": take.sessionId, "takeId": take.takeId,
                    "file": url.lastPathComponent, "durationSeconds": sidecar.duration, "bytes": bytes])
        uploader.enqueue(PendingUpload(sessionId: take.sessionId, takeId: take.takeId,
                                       camera: config?.name ?? ConfigStore.defaultName,
                                       videoFile: url.lastPathComponent, sidecarFile: sidecarName,
                                       clockOffsetMs: offsetMs))
    }

    // MARK: - Status

    private func sendHello() {
        relay.send(["type": "hello", "id": ConfigStore.deviceID, "name": config?.name ?? ConfigStore.defaultName,
                    "platform": "ios", "model": DeviceInfo.modelIdentifier, "os": DeviceInfo.osVersion,
                    "app": DeviceInfo.appVersion])
        sendStatus()
    }

    func sendStatus() {
        var status: [String: Any] = ["type": "status", "state": state.rawValue,
                                     "charging": [.charging, .full].contains(UIDevice.current.batteryState)]
        let battery = UIDevice.current.batteryLevel
        if battery >= 0 { status["battery"] = Double(battery) }
        if let free = DeviceInfo.freeBytes { status["freeBytes"] = free }
        if let take = currentTake { status["takeId"] = take.takeId }
        if let since = recordingSince { status["recordingSeconds"] = Date().timeIntervalSince(since) }
        if let upload { status["upload"] = ["bytesDone": upload.bytesDone, "bytesTotal": upload.bytesTotal] }
        if let lastError { status["error"] = lastError }
        relay.send(status)
    }
}

/// The per-take JSON next to the video (PROTOCOL.md), version 2: filled from the
/// finished file itself rather than from what was requested, plus the `clock` block.
struct Sidecar {
    var json: [String: Any]
    var duration: Double
    /// Log note if the file's video track does not start at 0 (it should).
    var firstFrameNote = ""

    /// PROTOCOL.md: samples from at least 10 minutes before the take.
    static let samplesBeforeNs: Int64 = 10 * ClockMath.minute

    struct Clock {
        var fileZeroDeviceNs: Int64
        var method: String
        var uncertaintyMs: Double
        var samples: [ClockSample]

        var json: [String: Any] {
            ["domain": "ios-hostTime",
             "fileZeroDeviceNs": fileZeroDeviceNs,
             "fileZeroMethod": method,
             "fileZeroUncertaintyMs": uncertaintyMs,
             "samples": samples.map(\.json)]
        }
    }

    static func make(for url: URL, sessionId: String, takeId: String, cameraName: String,
                     startWallClock: Date?, serverOffsetMs: Double?, clock: Clock) async -> Sidecar {
        let asset = AVURLAsset(url: url)
        var video: [String: Any] = [:]
        var audio: [String: Any] = [:]
        var duration = 0.0
        var note = ""
        if let d = try? await asset.load(.duration) { duration = d.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, fps, formats, range) = try? await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions, .timeRange) {
            video["width"] = Int(size.width)
            video["height"] = Int(size.height)
            video["fps"] = (Double(fps) * 1000).rounded() / 1000
            if let format = formats.first {
                let sub = CMFormatDescriptionGetMediaSubType(format)
                video["codec"] = sub == kCMVideoCodecType_HEVC ? "hevc" : sub == kCMVideoCodecType_H264 ? "h264" : fourCC(sub)
            }
            if range.start != .zero { note = ", WARNING video track starts at \(range.start.seconds) s" }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let formats = try? await track.load(.formatDescriptions), let format = formats.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            audio["sampleRate"] = Int(asbd.mSampleRate)
            audio["channels"] = Int(asbd.mChannelsPerFrame)
        }
        var json: [String: Any] = [
            "version": 2,
            "sessionId": sessionId,
            "takeId": takeId,
            "camera": ["id": ConfigStore.deviceID, "name": cameraName, "platform": "ios",
                       "model": DeviceInfo.modelIdentifier, "os": DeviceInfo.osVersion],
            "file": url.lastPathComponent,
            "video": video,
            "audio": audio,
            "durationSeconds": (duration * 1000).rounded() / 1000,
            "clock": clock.json,
        ]
        if let startWallClock { json["startWallClockMs"] = (startWallClock.timeIntervalSince1970 * 1000).rounded() }
        if let serverOffsetMs { json["serverOffsetMs"] = serverOffsetMs.rounded() }
        return Sidecar(json: json, duration: duration, firstFrameNote: note)
    }

    /// Merges every logged sample from 10 min before the take until now into the
    /// sidecar on disk. Returns the resulting sample count.
    @discardableResult
    static func refreshClockSamples(at url: URL, log: ClockLog, offsetMs: Double) -> Int {
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var clock = json["clock"] as? [String: Any],
              let zero = (clock["fileZeroDeviceNs"] as? NSNumber)?.int64Value else { return 0 }
        let existing = (clock["samples"] as? [[String: Any]] ?? []).compactMap(ClockSample.init(json:))
        let merged = ClockMath.merge(existing, log.samples(offsetMs: offsetMs, fromNs: zero - samplesBeforeNs))
        clock["samples"] = merged.map(\.json)
        json["clock"] = clock
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
        return merged.count
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}
