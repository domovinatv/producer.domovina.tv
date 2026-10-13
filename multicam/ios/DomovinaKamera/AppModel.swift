import AVFoundation
import UIKit

/// Ties the camera, the relay connection and the uploader together, and owns the
/// take state machine. `start` and `stop` are idempotent, as PROTOCOL.md requires:
/// the relay re-sends `start` to every camera that (re)connects during a take.
@MainActor
final class AppModel: ObservableObject {

    enum State: String { case idle, recording, uploading, error }

    @Published private(set) var config: RelayConfig?
    @Published private(set) var connected = false
    @Published private(set) var cameraReady = false
    @Published private(set) var recordingSince: Date?
    @Published private(set) var currentTake: (sessionId: String, takeId: String)?
    @Published private(set) var upload: Uploader.Progress?
    @Published private(set) var lastError: String?
    @Published var scanning = false {
        didSet { camera.setScanning(scanning) }
    }

    let camera = CameraController()
    private let relay = RelayClient()
    private let uploader = Uploader()
    private var statusTimer: Timer?
    private var pendingStart: (sessionId: String, takeId: String)?
    private var stopping = false
    private var sessionRunning = false
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        config = ConfigStore.load()

        relay.onConnectionChange = { [weak self] in self?.connected = $0 }
        relay.onConnected = { [weak self] in self?.sendHello() }
        relay.onCommand = { [weak self] in self?.handle($0) }

        uploader.onProgress = { [weak self] in self?.upload = $0; self?.sendStatus() }
        uploader.onError = { [weak self] in self?.lastError = $0; self?.sendStatus() }
        uploader.onUploaded = { [weak self] item in
            self?.relay.send(["type": "uploaded", "sessionId": item.sessionId, "takeId": item.takeId,
                              "objectKeys": [item.videoKey, item.sidecarKey].compactMap { $0 }])
            self?.sendStatus()
        }

        camera.onRecordingStarted = { [weak self] url, date in self?.recordingStarted(url, date) }
        camera.onRecordingFinished = { [weak self] url, error in self?.recordingFinished(url, error) }
        camera.onQRCode = { [weak self] value in
            guard let self, self.scanning, let url = URL(string: value) else { return }
            if self.apply(joinURL: url) { self.scanning = false }
        }

        if let config {
            relay.connect(config)
            uploader.setConfig(config)
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendStatus() }
        }
        Log.write("launch \(DeviceInfo.modelIdentifier) iOS \(DeviceInfo.osVersion) app \(DeviceInfo.appVersion), pending uploads \(uploader.pendingCount)")
    }

    func prepareCamera() {
        // The permission prompt waits for a tap on the phone; tell the director why
        // this camera is not ready instead of looking idle.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
            || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            lastError = "Čeka dozvolu za kameru i mikrofon na telefonu"
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start(sessionId: pending.sessionId, takeId: pending.takeId) }
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
            formatter.dateFormat = "yyyyMMdd-HHmm"
            let sid = "local-\(formatter.string(from: Date()))"
            start(sessionId: sid, takeId: sid)
        }
    }

    private func handle(_ command: RelayClient.Command) {
        switch command {
        case .start(let sessionId, let takeId): start(sessionId: sessionId, takeId: takeId)
        case .stop: stop()
        }
    }

    private func start(sessionId: String, takeId: String) {
        if currentTake?.takeId == takeId && currentTake?.sessionId == sessionId { return }
        if currentTake != nil || stopping {
            // A different take while one is running: finish the old one first.
            pendingStart = (sessionId, takeId)
            stop()
            return
        }
        guard sessionRunning else {
            pendingStart = (sessionId, takeId)
            Log.write("start \(takeId) deferred: camera not ready")
            return
        }
        currentTake = (sessionId, takeId)
        lastError = nil
        let url = documents.appendingPathComponent(Self.fileName(takeId))
        try? FileManager.default.removeItem(at: url)
        Log.write("start \(sessionId)/\(takeId)")
        camera.startRecording(to: url)
        sendStatus()
    }

    private func stop() {
        // A start still waiting for the camera is cancelled by a stop, too.
        if currentTake == nil { pendingStart = nil }
        guard currentTake != nil, !stopping else { return }
        stopping = true
        Log.write("stop \(currentTake?.takeId ?? "")")
        camera.stopRecording()
        // If recording never actually began (e.g. session not running), nothing will
        // call back; don't stay stuck in "recording".
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.stopping, self.recordingSince == nil else { return }
            self.stopping = false
            self.currentTake = nil
            self.lastError = "Snimanje nije krenulo"
            self.sendStatus()
        }
    }

    private static func fileName(_ takeId: String) -> String {
        let safe = takeId.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        return "take-\(safe).mov"
    }

    private var startWallClock: Date?

    private func recordingStarted(_ url: URL, _ date: Date) {
        recordingSince = date
        startWallClock = date
        guard let take = currentTake else { return }
        relay.send(["type": "recordingStarted", "sessionId": take.sessionId, "takeId": take.takeId,
                    "file": url.lastPathComponent, "wallClockMs": (date.timeIntervalSince1970 * 1000).rounded()])
        sendStatus()
    }

    private func recordingFinished(_ url: URL, _ error: Error?) {
        let take = currentTake
        let started = startWallClock
        recordingSince = nil
        currentTake = nil
        stopping = false
        if let error {
            lastError = "Snimka: \(error.localizedDescription)"
            Log.write("recording error: \(error)")
        }
        sendStatus()
        if let take, FileManager.default.fileExists(atPath: url.path) {
            Task { await self.finalize(url, take: take, started: started) }
        }
        if let next = pendingStart {
            pendingStart = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start(sessionId: next.sessionId, takeId: next.takeId) }
        }
    }

    private func finalize(_ url: URL, take: (sessionId: String, takeId: String), started: Date?) async {
        let sidecarName = "\(take.takeId.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)).json"
        let sidecar = await Sidecar.make(for: url, sessionId: take.sessionId, takeId: take.takeId,
                                         cameraName: config?.name ?? ConfigStore.defaultName,
                                         startWallClock: started, serverOffsetMs: relay.serverOffsetMs)
        do {
            let data = try JSONSerialization.data(withJSONObject: sidecar.json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: documents.appendingPathComponent(sidecarName))
        } catch {
            lastError = "Sidecar: \(error.localizedDescription)"
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        Log.write("finished \(take.takeId): \(bytes) B, \(String(format: "%.2f", sidecar.duration)) s")
        relay.send(["type": "recordingStopped", "sessionId": take.sessionId, "takeId": take.takeId,
                    "file": url.lastPathComponent, "durationSeconds": sidecar.duration, "bytes": bytes])
        uploader.enqueue(PendingUpload(sessionId: take.sessionId, takeId: take.takeId,
                                       camera: config?.name ?? ConfigStore.defaultName,
                                       videoFile: url.lastPathComponent, sidecarFile: sidecarName))
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

/// The per-take JSON next to the video (PROTOCOL.md), filled from the finished file
/// itself rather than from what was requested.
struct Sidecar {
    var json: [String: Any]
    var duration: Double

    static func make(for url: URL, sessionId: String, takeId: String, cameraName: String,
                     startWallClock: Date?, serverOffsetMs: Double?) async -> Sidecar {
        let asset = AVURLAsset(url: url)
        var video: [String: Any] = [:]
        var audio: [String: Any] = [:]
        var duration = 0.0
        if let d = try? await asset.load(.duration) { duration = d.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, fps, formats) = try? await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions) {
            video["width"] = Int(size.width)
            video["height"] = Int(size.height)
            video["fps"] = (Double(fps) * 1000).rounded() / 1000
            if let format = formats.first {
                let sub = CMFormatDescriptionGetMediaSubType(format)
                video["codec"] = sub == kCMVideoCodecType_HEVC ? "hevc" : sub == kCMVideoCodecType_H264 ? "h264" : fourCC(sub)
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let formats = try? await track.load(.formatDescriptions), let format = formats.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            audio["sampleRate"] = Int(asbd.mSampleRate)
            audio["channels"] = Int(asbd.mChannelsPerFrame)
        }
        var json: [String: Any] = [
            "version": 1,
            "sessionId": sessionId,
            "takeId": takeId,
            "camera": ["id": ConfigStore.deviceID, "name": cameraName, "platform": "ios",
                       "model": DeviceInfo.modelIdentifier, "os": DeviceInfo.osVersion],
            "file": url.lastPathComponent,
            "video": video,
            "audio": audio,
            "durationSeconds": (duration * 1000).rounded() / 1000,
        ]
        if let startWallClock { json["startWallClockMs"] = (startWallClock.timeIntervalSince1970 * 1000).rounded() }
        if let serverOffsetMs { json["serverOffsetMs"] = serverOffsetMs.rounded() }
        return Sidecar(json: json, duration: duration)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}
