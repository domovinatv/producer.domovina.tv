import Foundation
import SwiftUI
import AVFoundation
import Combine
import AppKit

/// Orchestrates a live take: microphones, camera, manifest, health and uploads.
///
/// Deliberate ordering on start — microphones first, then video, then the
/// upload queue. Audio is the one thing a podcast cannot survive losing, so it
/// is running before anything slower has a chance to fail.
@MainActor
final class StudioViewModel: ObservableObject {

    struct MicSlot: Identifiable, Equatable {
        var id: String
        var label: String
        var deviceUID: String?
    }

    // MARK: - Configuration

    @Published var sessionTitle: String = ""
    @Published var micSlots: [MicSlot] = [
        MicSlot(id: "mic-1", label: "Voditelj"),
        MicSlot(id: "mic-2", label: "Gost")
    ]
    @Published var selectedVideoDeviceID: String?
    @Published var selectedCameraAudioDeviceID: String?
    @Published var masterCodec: VideoCaptureController.MasterCodec = .hevc
    @Published var libraryURL: URL = SessionStore.defaultLibraryURL
    @Published var r2Configuration = R2ConfigurationStore.load()
    @Published var r2SecretInput: String = ""

    // MARK: - Discovered hardware

    @Published private(set) var availableInputs: [AudioInputDevice] = []
    @Published private(set) var availableVideoDevices: [AVCaptureDevice] = []
    @Published private(set) var availableCameraAudioDevices: [AVCaptureDevice] = []

    // MARK: - Live state

    @Published private(set) var isPreviewing = false
    /// Mirrored into `RecordingGuard` so the AppKit quit handler can see it.
    @Published private(set) var isRecording = false {
        didSet { RecordingGuard.shared.isRecording = isRecording }
    }
    @Published private(set) var isStopping = false
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var micStatuses: [String: AudioTrackRecorder.Status] = [:]
    @Published private(set) var videoStatus = VideoCaptureController.Status()
    @Published private(set) var lipSync = LipSyncMonitor.Reading()
    @Published private(set) var uploadStats = UploadQueue.Stats()
    @Published private(set) var health = HealthReport()
    @Published private(set) var sessionFolderURL: URL?
    @Published private(set) var recentEvents: [SessionManifest.Event] = []
    @Published var lastError: String?
    @Published var r2Status: String?

    let videoController = VideoCaptureController()
    private let lipSyncMonitor = LipSyncMonitor()
    private let healthMonitor = HealthMonitor()
    private let lipSyncQueue = DispatchQueue(label: "tv.domovina.studio.lipsync", qos: .utility)

    private var recorders: [String: AudioTrackRecorder] = [:]
    private var store: SessionStore?
    private var uploadQueue: UploadQueue?
    private var remotePrefix: String = ""
    private var startHostNanos: UInt64 = 0
    private var monitorErrors: [String] = []
    private var syncSampleTick = 0
    private var driftSampleTick = 0
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    // MARK: - Lifecycle

    init() {
        restoreSelections()
        refreshDevices()
        startTimers()

        deviceListener = AudioDeviceEnumerator.addDeviceListListener(queue: .main) { [weak self] in
            Task { @MainActor in self?.handleDeviceListChanged() }
        }
    }

    deinit {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
    }

    func refreshDevices() {
        availableInputs = AudioDeviceEnumerator.inputDevices()
        availableVideoDevices = VideoCaptureController.videoDevices()
        availableCameraAudioDevices = VideoCaptureController.audioDevices()

        if selectedVideoDeviceID == nil {
            // The Elgato is the only external video device in a normal studio.
            selectedVideoDeviceID = availableVideoDevices.first { $0.localizedName.localizedCaseInsensitiveContains("elgato") }?.uniqueID
                ?? availableVideoDevices.first?.uniqueID
        }
        if selectedCameraAudioDeviceID == nil {
            selectedCameraAudioDeviceID = availableCameraAudioDevices.first { $0.localizedName.localizedCaseInsensitiveContains("elgato") }?.uniqueID
        }
        autoAssignMicrophones()
    }

    /// Pre-fills the mic slots so a fresh machine is close to ready.
    ///
    /// Two topologies are possible and they need opposite treatment:
    ///
    /// * **Direct** — each PodMic USB is its own HAL device. One slot per mic,
    ///   isolated tracks, two clock domains to measure.
    /// * **RØDE Connect** — the app aggregates the mics itself and exposes
    ///   *virtual* devices. Then there is only ONE thing to capture, and filling
    ///   a second slot with another virtual device would record the wrong source
    ///   twice. `RØDE Connect System` in particular is system audio capture, not
    ///   microphones — assigning it would silently record whatever the Mac plays.
    private func autoAssignMicrophones() {
        let candidates: [AudioInputDevice]

        if isRodeConnectRunning, let mix = rodeConnectMixDevice {
            // Its processing is the reason to be on this path at all: two PodMics
            // a hand apart on a desk bleed into each other, and the per-channel
            // gating removes that at the source, live. Nothing in post recovers
            // it as cleanly.
            candidates = [mix]
        } else {
            let physical = availableInputs.filter {
                $0.name.localizedCaseInsensitiveContains("podmic")
                    && !$0.name.localizedCaseInsensitiveContains("connect")
            }
            if !physical.isEmpty {
                candidates = physical
            } else {
                // Virtual RØDE devices: never the system-audio one, and only one slot.
                let virtualMix = availableInputs.filter {
                    ($0.name.localizedCaseInsensitiveContains("rode") || $0.name.localizedCaseInsensitiveContains("røde"))
                        && !$0.name.localizedCaseInsensitiveContains("system")
                }
                candidates = Array(virtualMix.prefix(1))
            }
        }

        for (index, slot) in micSlots.enumerated() {
            guard slot.deviceUID == nil || availableInputs.first(where: { $0.uid == slot.deviceUID }) == nil else { continue }
            micSlots[index].deviceUID = index < candidates.count ? candidates[index].uid : nil
        }
    }

    /// The RØDE Connect driver installs its virtual devices permanently, so their
    /// presence says nothing — only the app being up means the mix is live.
    var isRodeConnectRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.rode.rodeconnect" }
    }

    /// Measured against a real RØDE Connect session: of the three virtual
    /// devices, only **Stream** carries the processed microphone mix. `Virtual`
    /// sits at digital silence and `System` is system-audio capture, which would
    /// record whatever the Mac happens to be playing.
    ///
    /// This does not depend on Monitor Out, which only decides where *you* listen.
    var rodeConnectMixDevice: AudioInputDevice? {
        availableInputs.first { $0.name.localizedCaseInsensitiveContains("connect stream") }
    }

    /// RØDE Connect is mixing, yet a slot is pointed at a physical microphone
    /// behind it — the raw, ungated signal the mixer was turned on to avoid.
    var isBypassingRodeConnect: Bool {
        guard isRodeConnectRunning, rodeConnectMixDevice != nil else { return false }
        return assignedMicrophones.contains { entry in
            entry.device.name.localizedCaseInsensitiveContains("podmic")
                && !entry.device.name.localizedCaseInsensitiveContains("connect")
        }
    }

    /// True when the assigned inputs are RØDE Connect virtual devices rather than
    /// the microphones themselves. Worth surfacing, because it changes what you
    /// get: one already-processed mix instead of isolated raw tracks.
    var isUsingAggregatedVirtualInput: Bool {
        let assigned = assignedMicrophones.map(\.device)
        guard !assigned.isEmpty else { return false }
        return assigned.allSatisfy { $0.name.localizedCaseInsensitiveContains("connect") }
    }

    private func handleDeviceListChanged() {
        let previouslyAssigned = Set(micSlots.compactMap(\.deviceUID))
        refreshDevices()
        let stillPresent = Set(availableInputs.map(\.uid))
        let lost = previouslyAssigned.subtracting(stillPresent)
        for uid in lost {
            let name = micSlots.first { $0.deviceUID == uid }?.label ?? uid
            store?.log("Audio uređaj nestao: \(name)", level: isRecording ? .error : .warning)
            if isRecording { lastError = "⚠️ Mikrofon '\(name)' je nestao iz sustava!" }
        }
    }

    // MARK: - Preview

    /// Brings up metering and video preview without writing anything.
    ///
    /// Audio monitoring is not optional here: with RØDE Connect installed there
    /// are three similarly named virtual devices and no way to tell which one
    /// carries the microphones except by watching a level meter while talking.
    /// Requiring a recording to find that out would be absurd.
    func startPreview() async {
        do {
            try await VideoCaptureController.requestPermissions()

            startAudioMonitors()

            if let videoDeviceID = selectedVideoDeviceID {
                videoController.masterCodec = masterCodec
                videoController.onMonitorSamples = { [weak self] samples, count, rate, hostNanos in
                    self?.lipSyncMonitor.feedCamera(samples: samples, count: count, sampleRate: rate, hostNanos: hostNanos)
                }
                try await videoController.startSession(videoDeviceID: videoDeviceID, audioDeviceID: selectedCameraAudioDeviceID)
            }

            isPreviewing = true
            lastError = monitorErrors.isEmpty ? nil : monitorErrors.joined(separator: "\n")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopPreview() {
        guard !isRecording else { return }
        stopAudioMonitors()
        videoController.stopSession()
        isPreviewing = false
    }

    private func startAudioMonitors() {
        stopAudioMonitors()
        monitorErrors = []
        lipSyncMonitor.reset()

        for (index, entry) in assignedMicrophones.enumerated() {
            let recorder = AudioTrackRecorder(
                trackID: entry.slot.id,
                label: entry.slot.label,
                device: entry.device,
                audioDirectory: FileManager.default.temporaryDirectory,
                segmentsDirectory: FileManager.default.temporaryDirectory
            )
            if index == 0 {
                recorder.onMonitorSamples = { [weak self] samples, count, rate, hostNanos in
                    self?.lipSyncMonitor.feedMicrophone(samples: samples, count: count, sampleRate: rate, hostNanos: hostNanos)
                }
            }
            do {
                try recorder.start(writesToDisk: false)
                recorders[entry.slot.id] = recorder
            } catch {
                monitorErrors.append("\(entry.slot.label): \(error.localizedDescription)")
            }
        }
    }

    private func stopAudioMonitors() {
        for recorder in recorders.values { recorder.stop() }
        recorders.removeAll()
        micStatuses = [:]
    }

    // MARK: - Recording

    var assignedMicrophones: [(slot: MicSlot, device: AudioInputDevice)] {
        micSlots.compactMap { slot in
            guard let uid = slot.deviceUID, let device = availableInputs.first(where: { $0.uid == uid }) else { return nil }
            return (slot, device)
        }
    }

    var estimatedGigabytesPerHour: Double {
        let audio = Double(assignedMicrophones.count) * 1.1   // continuous + segment copy
        guard isPreviewing || isRecording else { return audio }

        // Measured rate, not the format's ceiling: at 4K the difference between
        // 30 and the advertised 120 fps is a fourfold error in the ProRes
        // estimate, and this number is what the disk pre-flight refuses takes on.
        let video = masterCodec.approximateGigabytesPerHour(
            width: videoStatus.width,
            height: videoStatus.height,
            frameRate: videoStatus.measuredFrameRate ?? videoStatus.nominalFrameRate
        )
        return audio + video
    }

    func startRecording() async {
        guard !isRecording else { return }
        guard !assignedMicrophones.isEmpty else {
            lastError = "Dodijeli barem jedan mikrofon prije snimanja."
            return
        }

        // Video must not hinge on whether the preview toggle happened to be on.
        // A 104-minute take came out audio-only because it wasn't, and the only
        // sign was one warning line inside the session log — read for the first
        // time after the guests had gone home. If a camera is selected, bring
        // the capture session up ourselves.
        if selectedVideoDeviceID != nil, !isPreviewing {
            await startPreview()
            // The session needs a moment before it delivers frames; without this
            // the writer would start on the first audio buffer instead and the
            // take would open with a stretch of black.
            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        // Pre-flight: refuse rather than fail 40 minutes in.
        let preflight = healthMonitor.evaluate(
            sessionDirectory: libraryURL,
            estimatedGigabytesPerHour: estimatedGigabytesPerHour,
            microphones: [],
            video: nil,
            upload: UploadQueue.Stats(),
            isRecording: false,
            elapsedSeconds: 0
        )
        guard preflight.isSafeToRecord else {
            lastError = preflight.items.first { $0.severity == .critical }?.detail ?? "Sustav nije spreman."
            return
        }

        do {
            let newStore = try SessionStore(libraryURL: libraryURL, title: sessionTitle)
            store = newStore
            sessionFolderURL = newStore.rootURL
            startHostNanos = HostClock.now()
            lipSyncMonitor.reset()

            remotePrefix = "\(r2Configuration.prefix)/\(newStore.snapshot().sessionID)"
            let queue = UploadQueue(
                journalURL: newStore.rootURL.appendingPathComponent("upload-journal.json"),
                configuration: r2Configuration
            )
            uploadQueue = queue

            newStore.mutate {
                $0.startedAtHostNanos = self.startHostNanos
                $0.cameraAVOffsetMilliseconds = self.cameraAVOffsetMilliseconds
                if self.r2Configuration.isUsable {
                    $0.remote = .init(provider: "cloudflare-r2", bucket: self.r2Configuration.bucket, prefix: self.remotePrefix)
                }
            }
            newStore.log("Snimanje pokrenuto", level: .info)

            try startMicrophones(store: newStore, queue: queue)
            let videoStarted = startVideo(store: newStore, queue: queue)

            isRecording = true
            elapsedSeconds = 0
            // Only clear the error line if there is nothing left to say. Wiping
            // it unconditionally is what let a 104-minute take look perfectly
            // healthy on screen while it recorded no picture at all.
            if videoStarted { lastError = nil }
        } catch {
            lastError = error.localizedDescription
            await teardownRecorders()
        }
    }

    private func startMicrophones(store: SessionStore, queue: UploadQueue) throws {
        // Monitors hold the same HAL devices with file writing switched off —
        // they must be released before the real recorders take over, or they
        // would be orphaned in the recorders dictionary and keep running.
        stopAudioMonitors()

        for (index, entry) in assignedMicrophones.enumerated() {
            let recorder = AudioTrackRecorder(
                trackID: entry.slot.id,
                label: entry.slot.label,
                device: entry.device,
                audioDirectory: store.audioURL,
                segmentsDirectory: store.segmentsURL
            )

            let trackID = entry.slot.id
            let isPrimary = index == 0
            let uploadDuringRecording = r2Configuration.uploadDuringRecording

            recorder.onSegmentReady = { [weak self] url, segmentIndex, hostNanos, duration in
                guard let self else { return }
                let key = "\(self.remotePrefix)/audio/\(trackID)/\(url.lastPathComponent)"
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0

                store.mutate { manifest in
                    guard let trackIndex = manifest.tracks.firstIndex(where: { $0.id == trackID }) else { return }
                    manifest.tracks[trackIndex].segments.append(
                        .init(index: segmentIndex,
                              relativePath: store.relativePath(for: url),
                              remoteKey: key,
                              byteCount: size,
                              startHostNanos: hostNanos,
                              durationSeconds: duration)
                    )
                }

                if uploadDuringRecording {
                    Task {
                        // The continuous master stays on disk, so the segment
                        // copy is disposable once it is safely in R2.
                        await queue.enqueue(fileURL: url, remoteKey: key, kind: .audioSegment,
                                            contentType: "audio/wav", deleteLocalAfterUpload: true)
                    }
                }
            }

            if isPrimary {
                recorder.onMonitorSamples = { [weak self] samples, count, rate, hostNanos in
                    self?.lipSyncMonitor.feedMicrophone(samples: samples, count: count, sampleRate: rate, hostNanos: hostNanos)
                }
            }

            try recorder.start()
            recorders[entry.slot.id] = recorder

            store.mutate {
                $0.upsert(track: .init(
                    id: entry.slot.id,
                    kind: .microphone,
                    label: entry.slot.label,
                    deviceName: entry.device.name,
                    deviceUID: entry.device.uid,
                    relativePath: store.relativePath(for: recorder.localFileURL),
                    sampleRate: entry.device.nominalSampleRate,
                    channelCount: entry.device.inputChannelCount,
                    bitDepth: 24
                ))
            }
            store.log("Mikrofon '\(entry.slot.label)' snima s \(entry.device.name)")
        }
    }

    /// Returns whether the camera is actually recording, so the caller can leave
    /// the warning on screen if it is not.
    private func startVideo(store: SessionStore, queue: UploadQueue) -> Bool {
        // Losing the camera for a whole take is not a warning-level event, so it
        // is surfaced where the operator is looking rather than only in the log.
        //
        // This has already cost a 104-minute take: macOS asks for camera access
        // on first use, the prompt went unanswered, and recording then went ahead
        // with audio alone. The only trace was one line inside the session log,
        // read for the first time long after the guests had left.
        //
        // Keyed on `isSessionRunning` rather than `isPreviewing`, because the
        // session is what produces frames — and it stays false when TCC refuses.
        guard selectedVideoDeviceID != nil else {
            lastError = "⚠️ SNIMA SE SAMO ZVUK — nije odabrana kamera."
            store.log("Video nije aktivan: nije odabrana kamera — snima se samo audio", level: .error)
            return false
        }
        guard videoController.snapshot().isSessionRunning else {
            lastError = "⚠️ SNIMA SE SAMO ZVUK — kamera nije dostupna. Provjeri dopuštenje u Postavkama → Privatnost i sigurnost → Kamera."
            store.log("Video nije aktivan: capture sesija nije pokrenuta (dopuštenje?) — snima se samo audio", level: .error)
            return false
        }

        let masterURL = store.videoURL.appendingPathComponent("camera-proxy.mov")
        // The fMP4 chunks exist only in memory until the uploader stages them,
        // and the uploader drops everything when R2 is off. Recording a local
        // path for a file that was never written makes the manifest claim
        // segments that recovery would then fail to find.
        let uploadDuringRecording = r2Configuration.uploadDuringRecording && r2Configuration.isUsable
        let stagingRoot = store.segmentsURL.appendingPathComponent("video", isDirectory: true)

        videoController.onSegmentReady = { [weak self] data, index, hostNanos, isInitialization in
            guard let self else { return }
            // The initialization segment gets a name that sorts first and reads
            // unambiguously, so recovery never has to infer it from an index.
            let name = isInitialization
                ? "video-init.mp4"
                : String(format: "video-%05d.m4s", index)
            let key = "\(self.remotePrefix)/video/segments/\(name)"

            store.mutate { manifest in
                guard let trackIndex = manifest.tracks.firstIndex(where: { $0.id == "camera-proxy" }) else { return }
                manifest.tracks[trackIndex].segments.append(
                    .init(index: index,
                          relativePath: uploadDuringRecording ? "segments/video/\(name)" : nil,
                          remoteKey: key,
                          byteCount: data.count,
                          startHostNanos: hostNanos,
                          durationSeconds: isInitialization ? 0 : self.videoController.uploadSegmentSeconds,
                          isInitialization: isInitialization)
                )
            }

            if uploadDuringRecording {
                Task {
                    await queue.enqueue(data: data,
                                        stagingURL: stagingRoot.appendingPathComponent(name),
                                        remoteKey: key,
                                        kind: .videoSegment,
                                        contentType: "video/mp4",
                                        deleteLocalAfterUpload: true)
                }
            }
        }

        do {
            try videoController.startRecording(masterURL: masterURL)
            let status = videoController.snapshot()
            store.mutate {
                $0.upsert(track: .init(
                    id: "camera-proxy",
                    kind: .cameraProxyVideo,
                    label: "Elgato / GH5 proxy",
                    deviceName: self.availableVideoDevices.first { $0.uniqueID == self.selectedVideoDeviceID }?.localizedName ?? "Elgato",
                    deviceUID: self.selectedVideoDeviceID,
                    relativePath: store.relativePath(for: masterURL),
                    codec: self.masterCodec.rawValue,
                    width: status.width,
                    height: status.height,
                    nominalFrameRate: status.nominalFrameRate
                ))
            }
            store.log("Video snimanje pokrenuto (\(status.width)×\(status.height) @ \(Int(status.nominalFrameRate))fps, \(masterCodec.displayName))")
            return true
        } catch {
            lastError = "⚠️ SNIMA SE SAMO ZVUK — \(error.localizedDescription)"
            store.log("Video snimanje NIJE pokrenuto: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    func stopRecording() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        let store = self.store
        let stopHostNanos = HostClock.now()

        let finalSnapshots = await teardownRecorders()

        store?.mutate { $0.stoppedAtHostNanos = stopHostNanos }
        store?.log("Snimanje zaustavljeno")
        writeFinalTrackStatistics(microphones: finalSnapshots)

        // Say out loud whether post has what it needs to fix lip sync, because
        // discovering it does not is a lot worse in the edit than here.
        if let manifest = store?.snapshot() {
            if let offset = manifest.resolvedSyncOffsetMilliseconds {
                store?.log(String(
                    format: "Izmjeren pomak mikrofon→slika: %+.1f ms (%d mjerenja) — primijenit će ga finalize_session.sh",
                    offset, manifest.syncMeasurements.count
                ))
            } else if manifest.tracks.contains(where: { $0.kind == .cameraProxyVideo }) {
                store?.log(
                    "Nema dovoljno pouzdanih mjerenja lip synca — provjeri je li HDMI zvuk iz kamere bio odabran.",
                    level: .warning
                )
            }
        }
        store?.saveNow()

        isRecording = false

        if let store, r2Configuration.isUsable {
            await uploadFinalArtifacts(store: store)
        }
    }

    /// Returns each microphone's final counters, because after this the
    /// recorders are gone and the numbers with them.
    @discardableResult
    private func teardownRecorders() async -> [String: AudioTrackRecorder.Status] {
        for recorder in recorders.values { recorder.stop() }

        // Read the statistics here, while the recorders still exist. `stop()`
        // has already drained the writer queue, so these are the final counts.
        // Taking them after `removeAll()` — which is what this method used to
        // do — returned an empty dictionary, and the manifest lost every
        // microphone's `firstSampleHostNanos`, sample count and drift.
        // Nothing failed visibly: finalize_session.sh treats a missing
        // `firstSampleHostNanos` as offset 0, so every take came out silently
        // misaligned by whatever the real start delta was.
        let snapshots = recorderSnapshots

        await videoController.stopRecording()
        recorders.removeAll()
        return snapshots
    }

    /// Freezes the measured drift and sample counts into the manifest — the
    /// numbers post-production needs to resample each mic onto one timeline.
    private func writeFinalTrackStatistics(microphones snapshots: [String: AudioTrackRecorder.Status]) {
        guard let store else { return }
        let videoSnapshot = videoController.snapshot()

        store.mutate { manifest in
            for (trackID, status) in snapshots {
                guard let index = manifest.tracks.firstIndex(where: { $0.id == trackID }) else { continue }
                manifest.tracks[index].firstSampleHostNanos = status.firstSampleHostNanos
                manifest.tracks[index].sampleCount = status.frameCount
                manifest.tracks[index].measuredSampleRate = status.measuredSampleRate
                manifest.tracks[index].driftPPM = status.driftPPM
                manifest.tracks[index].clipCount = status.levels.clipCount
            }
            if let index = manifest.tracks.firstIndex(where: { $0.id == "camera-proxy" }) {
                manifest.tracks[index].firstSampleHostNanos = videoSnapshot.firstVideoHostNanos
                manifest.tracks[index].lastSampleHostNanos = videoSnapshot.lastVideoHostNanos
                manifest.tracks[index].sampleCount = videoSnapshot.videoFrameCount
                manifest.tracks[index].measuredFrameRate = videoSnapshot.measuredFrameRate
            }
        }
    }

    private var recorderSnapshots: [String: AudioTrackRecorder.Status] {
        var result: [String: AudioTrackRecorder.Status] = [:]
        for (id, recorder) in recorders { result[id] = recorder.snapshot() }
        return result
    }

    private func uploadFinalArtifacts(store: SessionStore) async {
        guard let queue = uploadQueue else { return }

        await queue.enqueue(fileURL: store.manifestURL,
                            remoteKey: "\(remotePrefix)/manifest.json",
                            kind: .manifest,
                            contentType: "application/json",
                            deleteLocalAfterUpload: false)

        if r2Configuration.uploadMastersAfterStop {
            for track in store.snapshot().tracks {
                let localURL = store.rootURL.appendingPathComponent(track.relativePath)
                guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
                let contentType = track.kind == .cameraProxyVideo ? "video/quicktime" : "audio/wav"
                await queue.enqueue(fileURL: localURL,
                                    remoteKey: "\(remotePrefix)/masters/\(localURL.lastPathComponent)",
                                    kind: .master,
                                    contentType: contentType,
                                    deleteLocalAfterUpload: false)
            }
        }

        // Don't block the UI on this — masters can take a long time on a normal
        // upload link. The session log gets an honest entry either way, so you
        // can tell "off-site" from "still going" after the fact.
        Task.detached { [weak self] in
            let drained = await queue.waitUntilDrained(timeout: 6 * 3600)
            let stats = await queue.currentStats()
            guard let model = self else { return }
            await model.recordUploadOutcome(drained: drained, stats: stats)
        }
    }

    private func recordUploadOutcome(drained: Bool, stats: UploadQueue.Stats) {
        if drained && stats.failed == 0 {
            store?.log("Sve je poslano na Cloudflare R2 (\(stats.done) objekata)")
        } else {
            store?.log(
                "R2 upload nije dovršen: \(stats.failed) neuspješnih, \(stats.pending + stats.uploading) preostalo",
                level: .warning
            )
        }
        store?.saveNow()
    }

    // MARK: - Markers

    func addMarker(_ text: String) {
        store?.log(text, level: .info, isMarker: true)
    }

    func retryFailedUploads() async {
        await uploadQueue?.retryFailed()
    }

    // MARK: - Camera A/V calibration

    @Published private(set) var cameraAVOffsetMilliseconds: Double? = CameraCalibrationStore.offsetMilliseconds
    private(set) var calibrationClipURL: URL?

    func refreshCalibration() {
        cameraAVOffsetMilliseconds = CameraCalibrationStore.offsetMilliseconds
    }

    /// The offset post-production should apply: what the correlator measured, minus
    /// the camera's own internal A/V offset. Without the calibration term this is
    /// the raw correlation, which is right only if the camera's HDMI audio is
    /// aligned with its picture.
    var calibratedLipSyncMilliseconds: Double? {
        guard lipSync.isValid else { return nil }
        return lipSync.offsetMilliseconds - (cameraAVOffsetMilliseconds ?? 0)
    }

    /// Records a short clip carrying both the picture and the HDMI audio, which is
    /// all the calibration measurement needs. Deliberately separate from a real
    /// take: no microphones, no manifest, no upload.
    func recordCalibrationClip(seconds: Int, onTick: @escaping (Int) -> Void) async throws {
        guard isPreviewing else {
            throw VideoCaptureController.CaptureError.noVideoDevice
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("domovina-calibration-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        // The upload-tier writer is irrelevant here and would only burn CPU.
        videoController.onSegmentReady = nil
        try videoController.startRecording(masterURL: url)

        for remaining in stride(from: seconds, through: 1, by: -1) {
            onTick(remaining)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        onTick(0)

        await videoController.stopRecording()
        calibrationClipURL = url
    }

    func discardCalibrationClip() {
        if let url = calibrationClipURL {
            try? FileManager.default.removeItem(at: url)
        }
        calibrationClipURL = nil
    }

    // MARK: - Timers

    private func startTimers() {
        fastTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFast() }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickSlow() }
        }
    }

    private func tickFast() {
        micStatuses = recorderSnapshots
        videoStatus = videoController.snapshot()
        if isRecording {
            elapsedSeconds = Double(HostClock.now() - startHostNanos) / 1_000_000_000.0
        }
    }

    private func tickSlow() async {
        // Correlation runs off the main thread; the result is read next tick.
        lipSyncQueue.async { [lipSyncMonitor] in lipSyncMonitor.recompute() }
        lipSync = lipSyncMonitor.snapshot()
        recordSyncMeasurementIfDue()

        if let queue = uploadQueue {
            uploadStats = await queue.currentStats()
        }

        let microphones = micSlots.compactMap { slot -> (label: String, levels: LevelMeter.Reading, isRunning: Bool)? in
            guard slot.deviceUID != nil else { return nil }
            guard let status = micStatuses[slot.id] else {
                return isRecording ? (slot.label, LevelMeter.Reading(), false) : nil
            }
            return (slot.label, status.levels, status.isRunning)
        }

        health = healthMonitor.evaluate(
            sessionDirectory: sessionFolderURL ?? libraryURL,
            estimatedGigabytesPerHour: estimatedGigabytesPerHour,
            microphones: microphones,
            // Keyed on a camera being selected, not on preview: the dead-camera
            // check is worth the most during a take, which is exactly when
            // preview may have been switched off.
            video: selectedVideoDeviceID != nil ? videoStatus : nil,
            upload: uploadStats,
            isRecording: isRecording,
            elapsedSeconds: elapsedSeconds,
            isBypassingRodeConnect: isBypassingRodeConnect
        )

        if let store {
            recentEvents = Array(store.snapshot().events.suffix(40).reversed())
        }
    }

    private func recordDriftSamples(store: SessionStore) {
        let snapshots = recorderSnapshots
        store.mutate { manifest in
            for (trackID, status) in snapshots {
                guard let hostNanos = status.lastBufferHostNanos, status.frameCount > 0,
                      let index = manifest.tracks.firstIndex(where: { $0.id == trackID }) else { continue }
                manifest.tracks[index].driftSamples.append(
                    .init(hostNanos: hostNanos, frameCount: status.frameCount)
                )
            }
        }
    }

    /// Persists the measured microphone→picture offset every few seconds.
    ///
    /// Without this the correlator is only a light on the dashboard: the host
    /// clock cannot see pipeline latency, so post has nothing to correct with.
    /// Storing the series rather than a running average is deliberate — it is
    /// the only way to tell a constant offset from one that walks over 180
    /// minutes.
    private func recordSyncMeasurementIfDue() {
        guard isRecording, let store else { return }

        // Drift trajectory: one point per 30 s is plenty to characterise a
        // crystal, and keeps the manifest small on a 3-hour take (360 points).
        // Counted separately from the sync tick, which resets.
        driftSampleTick += 1
        if driftSampleTick >= 30 {
            driftSampleTick = 0
            recordDriftSamples(store: store)
        }

        syncSampleTick += 1
        guard syncSampleTick >= 5 else { return }   // tickSlow runs at 1 Hz
        syncSampleTick = 0

        let reading = lipSync
        guard reading.isValid else { return }       // silence in the room, nothing to learn

        store.mutate {
            $0.syncMeasurements.append(
                .init(
                    hostNanos: HostClock.now(),
                    offsetMilliseconds: reading.offsetMilliseconds,
                    confidence: reading.confidence,
                    clockOffsetMilliseconds: reading.clockOffsetMilliseconds
                )
            )
        }
    }

    // MARK: - R2 settings

    func saveR2Configuration() {
        R2ConfigurationStore.save(r2Configuration)
        if !r2SecretInput.isEmpty {
            R2ConfigurationStore.saveSecret(r2SecretInput, forAccessKeyID: r2Configuration.accessKeyID)
            r2SecretInput = ""
        }
        persistSelections()
    }

    func verifyR2Access() async {
        r2Status = "Provjeravam…"
        do {
            let client = try R2Client(configuration: r2Configuration)
            try await client.verifyAccess()
            r2Status = "✅ Veza s R2 radi (bucket: \(r2Configuration.bucket))"
        } catch {
            r2Status = "❌ \(error.localizedDescription)"
        }
    }

    var hasStoredR2Secret: Bool {
        R2ConfigurationStore.hasSecret(forAccessKeyID: r2Configuration.accessKeyID)
    }

    // MARK: - Selection persistence

    private func persistSelections() {
        let defaults = UserDefaults.standard
        defaults.set(selectedVideoDeviceID, forKey: "studio.videoDevice")
        defaults.set(selectedCameraAudioDeviceID, forKey: "studio.cameraAudioDevice")
        defaults.set(masterCodec.rawValue, forKey: "studio.masterCodec")
        defaults.set(libraryURL.path, forKey: "studio.library")
        let encoded = micSlots.map { ["id": $0.id, "label": $0.label, "uid": $0.deviceUID ?? ""] }
        defaults.set(encoded, forKey: "studio.micSlots")
    }

    private func restoreSelections() {
        let defaults = UserDefaults.standard
        selectedVideoDeviceID = defaults.string(forKey: "studio.videoDevice")
        selectedCameraAudioDeviceID = defaults.string(forKey: "studio.cameraAudioDevice")
        if let raw = defaults.string(forKey: "studio.masterCodec"),
           let codec = VideoCaptureController.MasterCodec(rawValue: raw) {
            masterCodec = codec
        }
        if let path = defaults.string(forKey: "studio.library"), !path.isEmpty {
            libraryURL = URL(fileURLWithPath: path)
        }
        if let stored = defaults.array(forKey: "studio.micSlots") as? [[String: String]], !stored.isEmpty {
            micSlots = stored.map {
                MicSlot(id: $0["id"] ?? UUID().uuidString,
                        label: $0["label"] ?? "Mikrofon",
                        deviceUID: ($0["uid"]?.isEmpty ?? true) ? nil : $0["uid"])
            }
        }
    }

    func commitSelections() { persistSelections() }

    func addMicSlot() {
        micSlots.append(MicSlot(id: "mic-\(micSlots.count + 1)", label: "Mikrofon \(micSlots.count + 1)"))
    }

    func removeMicSlot(id: String) {
        guard !isRecording else { return }
        micSlots.removeAll { $0.id == id }
    }

    // MARK: - Post-production hand-off

    /// The exact command to run once the GH5's SD card is plugged in.
    func finalizeCommand(lumixFiles: [String]) -> String? {
        guard let folder = sessionFolderURL else { return nil }
        let scriptPath = ScriptLocator.finalizeScriptPath() ?? "./scripts/finalize_session.sh"
        var parts = ["time", scriptPath, "\\\n  --session", "\"\(folder.path)\""]
        for file in lumixFiles {
            parts.append(contentsOf: ["\\\n  --lumix", "\"\(file)\""])
        }
        return parts.joined(separator: " ")
    }
}

enum ScriptLocator {

    static func finalizeScriptPath() -> String? {
        candidates(named: "scripts/finalize_session.sh").first
    }

    static func syncScriptPath() -> String? {
        candidates(named: "podcast_sync.sh").first
    }

    private static func candidates(named relativePath: String) -> [String] {
        let cwd = FileManager.default.currentDirectoryPath
        let possibilities = [
            "\(cwd)/\(relativePath)",
            "\(cwd)/../\(relativePath)",
            "\(NSHomeDirectory())/git/domovinatv/producer.domovina.tv/\(relativePath)"
        ]
        return possibilities
            .map { ($0 as NSString).standardizingPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}
