import AVFoundation
import UIKit

/// Owns the capture session. Every touch of the session, its inputs and outputs
/// happens on `sessionQueue` — the Mac app once crashed from setting a preview
/// layer's session on main while `startRunning()` raced it on another thread. The
/// preview layer is given the session exactly once, before `startRunning()` is
/// queued.
///
/// Recording: AVCaptureVideoDataOutput + AVCaptureAudioDataOutput into one
/// AVAssetWriter (`TakeWriter`). Both outputs deliver on `outputQueue`, which alone
/// owns the writer. Picture and the built-in mic are stamped by the same session
/// clock in the same file — that is what makes this phone's own audio a trustworthy
/// reference — and unlike AVCaptureMovieFileOutput this gives the exact capture time
/// of the file's first frame (`fileZeroDeviceNs`, PROTOCOL.md "Sat").
final class CameraController: NSObject {

    struct StartInfo {
        let url: URL
        /// Host-clock ns of PTS 0 of the video track (= the first frame's capture PTS).
        let fileZeroDeviceNs: Int64
        let wallClock: Date
        let method: String
        let uncertaintyMs: Double
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tv.domovina.multicam.camera")
    private let outputQueue = DispatchQueue(label: "tv.domovina.multicam.output", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var device: AVCaptureDevice?
    private var videoCodec: AVVideoCodecType = .hevc

    // outputQueue only:
    private var writer: TakeWriter?
    /// The clock sample-buffer PTS are on; nil = host clock (checked at start).
    private var syncClock: CMClock?
    private var clockIsHost = true

    /// Called on the main queue.
    var onRecordingStarted: ((StartInfo) -> Void)?
    /// URL is nil when no file was created. Called on the main queue.
    var onRecordingFinished: ((URL?, Error?) -> Void)?
    /// The session was interrupted or failed (e.g. app backgrounded). Main queue.
    var onInterrupted: ((String) -> Void)?
    var onQRCode: ((String) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).map { "prekid \($0)" } ?? "prekid"
            self?.onInterrupted?(reason)
        }
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onInterrupted?("greška kamere: \(error?.localizedDescription ?? "?")")
        }
    }

    /// Asks for camera and mic, configures, and calls back on main with an error
    /// message or nil. Does not start the session.
    func prepare(completion: @escaping (String?) -> Void) {
        Task {
            let video = await AVCaptureDevice.requestAccess(for: .video)
            let audio = await AVCaptureDevice.requestAccess(for: .audio)
            guard video, audio else {
                await MainActor.run {
                    completion(video ? "Nema dozvole za mikrofon (Postavke → DOMOVINA Kamera)"
                                     : "Nema dozvole za kameru (Postavke → DOMOVINA Kamera)")
                }
                return
            }
            sessionQueue.async {
                let error = self.configure()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func startRunning(completion: @escaping () -> Void) {
        sessionQueue.async {
            guard !self.session.isRunning else { DispatchQueue.main.async(execute: completion); return }
            self.session.startRunning()
            // Re-assert after start: some formats reset frame duration when the
            // session commits. Constant 30 fps is what post relies on.
            self.lockFrameRate()
            let clock = self.session.synchronizationClock
            let isHost = clock.map { CFEqual($0, CMClockGetHostTimeClock()) } ?? true
            Log.write("session running: \(self.session.isRunning), sync clock \(clock == nil ? "nil (host assumed)" : isHost ? "= host time clock" : "≠ host, converting with CMSyncConvertTime")")
            self.outputQueue.async {
                self.syncClock = clock
                self.clockIsHost = isHost
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func configure() -> String? {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try? audioSession.setPreferredSampleRate(48_000)
            try audioSession.setActive(true)
            Log.write("audio session \(audioSession.sampleRate) Hz")
        } catch {
            Log.write("audio session: \(error)")
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return "Stražnja kamera nije dostupna"
        }
        device = camera
        guard let videoInput = try? AVCaptureDeviceInput(device: camera), session.canAddInput(videoInput) else {
            return "Kamera se ne može otvoriti"
        }
        session.addInput(videoInput)

        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(audioInput) {
            session.addInput(audioInput)
        } else {
            return "Mikrofon se ne može otvoriti"
        }

        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else { return "Snimanje slike nije podržano" }
        session.addOutput(videoOutput)
        audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(audioOutput) else { return "Snimanje zvuka nije podržano" }
        session.addOutput(audioOutput)
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = []
        }

        guard let format = Self.pickFormat(camera) else { return "Kamera ne podržava 1080p30" }
        do {
            try camera.lockForConfiguration()
            camera.activeFormat = format
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            camera.unlockForConfiguration()
        } catch {
            return "Kamera zaključana: \(error.localizedDescription)"
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            // landscapeRight is the back sensor's native orientation: no rotation cost.
            if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
        }
        videoCodec = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov).contains(.hevc) ? .hevc : .h264
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        Log.write("configured \(dims.width)x\(dims.height) \(format.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" }) codec \(videoCodec.rawValue)")
        return nil
    }

    /// 1920×1080, 8-bit, able to do 30 fps — preferring the format whose ceiling is
    /// closest to 30 (fewer binned/high-speed modes) and a full-range pixel format.
    private static func pickFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return d.width == 1920 && d.height == 1080
                && (sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        func ceiling(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        return candidates.min { a, b in
            if ceiling(a) != ceiling(b) { return ceiling(a) < ceiling(b) }
            let fullA = CMFormatDescriptionGetMediaSubType(a.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let fullB = CMFormatDescriptionGetMediaSubType(b.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return fullA && !fullB
        }
    }

    private func lockFrameRate() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
    }

    /// Arms a writer; the file starts at the first frame captured at or after
    /// `atHostNs` (host clock), so a scheduled start is frame-accurate rather than
    /// timer-accurate.
    func startRecording(to url: URL, atHostNs: Int64) {
        outputQueue.async {
            guard self.writer == nil else {
                Log.write("startRecording ignored: writer busy")
                return
            }
            let startAt = self.sourceTime(hostNs: atHostNs)
            do {
                self.writer = try TakeWriter(url: url, videoSettings: TakeWriter.videoSettings(codec: self.videoCodec),
                                             audioSettings: TakeWriter.audioSettings, startAt: startAt)
            } catch {
                Log.write("writer init failed: \(error)")
                DispatchQueue.main.async { self.onRecordingFinished?(nil, error) }
            }
        }
    }

    func stopRecording() {
        outputQueue.async { self.finishWriter() }
    }

    /// outputQueue only.
    private func finishWriter() {
        guard let writer else {
            DispatchQueue.main.async { self.onRecordingFinished?(nil, nil) }
            return
        }
        self.writer = nil
        let stats = writer.stats
        let url = writer.url
        writer.finish { error in
            Log.write("writer finished: \(stats.videoFrames) frames, \(stats.audioBuffers) audio buffers, dropped video \(stats.videoDroppedNotReady), audio before start \(stats.audioDroppedBeforeStart), audio not ready \(stats.audioDroppedNotReady)\(error.map { ", error \($0)" } ?? "")")
            let notStarted: Bool
            if case TakeWriter.WriterError.notStarted? = error { notStarted = true } else { notStarted = false }
            DispatchQueue.main.async { self.onRecordingFinished?(notStarted ? nil : url, error) }
        }
    }

    /// Host ns → the sample buffers' clock.
    private func sourceTime(hostNs: Int64) -> CMTime {
        let host = HostClock.hostTime(ns: hostNs)
        guard !clockIsHost, let syncClock else { return host }
        return CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: syncClock)
    }

    /// The sample buffers' clock → host ns.
    private func hostNs(sourceTime: CMTime) -> Int64 {
        guard !clockIsHost, let syncClock else { return HostClock.ns(fromHostTime: sourceTime) }
        return HostClock.ns(fromHostTime: CMSyncConvertTime(sourceTime, from: syncClock, to: CMClockGetHostTimeClock()))
    }

    func setScanning(_ on: Bool) {
        sessionQueue.async {
            let types: [AVMetadataObject.ObjectType] = on && self.metadataOutput.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
            self.metadataOutput.metadataObjectTypes = types
        }
    }
}

/// State is confined to `sessionQueue` / `outputQueue` as documented above.
extension CameraController: @unchecked Sendable {}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer else { return }
        if output === videoOutput {
            if writer.appendVideo(sampleBuffer), let zero = writer.fileZeroSourceTime {
                let zeroNs = hostNs(sourceTime: zero)
                // Wall clock of the same instant, for the v1 field: now minus how
                // long ago the frame was captured.
                let wall = Date(timeIntervalSinceNow: -Double(HostClock.nowNs() - zeroNs) / 1e9)
                let info = StartInfo(
                    url: writer.url, fileZeroDeviceNs: zeroNs, wallClock: wall,
                    method: clockIsHost
                        ? "AVAssetWriter.startSession(atSourceTime:) = PTS of first AVCaptureVideoDataOutput frame; session synchronizationClock is the host time clock, PTS used directly"
                        : "AVAssetWriter.startSession(atSourceTime:) = PTS of first AVCaptureVideoDataOutput frame, converted from session synchronizationClock to host time with CMSyncConvertTime",
                    // The PTS→host mapping is exact (or one CMSyncConvertTime); what
                    // remains is what the sensor timestamp itself means relative to
                    // the exposure, which iOS does not document.
                    uncertaintyMs: clockIsHost ? 1.0 : 2.0)
                DispatchQueue.main.async { self.onRecordingStarted?(info) }
            }
        } else if output === audioOutput {
            writer.appendAudio(sampleBuffer)
        }
        if let error = writer.failure {
            Log.write("writer failed mid-take: \(error)")
            finishWriter()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard writer != nil, output === videoOutput else { return }
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        Log.write("capture dropped a frame: \(reason.map { "\($0)" } ?? "?")")
    }
}

extension CameraController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
            if let value = code.stringValue { onQRCode?(value) }
        }
    }
}
