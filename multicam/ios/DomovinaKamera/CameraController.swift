import AVFoundation
import UIKit

/// Owns the capture session. Every touch of the session, its inputs and outputs
/// happens on `queue` — the Mac app once crashed from setting a preview layer's
/// session on main while `startRunning()` raced it on another thread. The preview
/// layer is given the session exactly once, before `startRunning()` is queued.
///
/// Video and the built-in mic go into one AVCaptureMovieFileOutput, so both are
/// stamped by the same clock in the same file. That is what makes this phone's own
/// audio a trustworthy reference for aligning its picture in post.
final class CameraController: NSObject {

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "tv.domovina.multicam.camera")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var device: AVCaptureDevice?

    /// Called on the main queue.
    var onRecordingStarted: ((URL, Date) -> Void)?
    var onRecordingFinished: ((URL, Error?) -> Void)?
    var onQRCode: ((String) -> Void)?

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
            queue.async {
                let error = self.configure()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func startRunning(completion: @escaping () -> Void) {
        queue.async {
            guard !self.session.isRunning else { DispatchQueue.main.async(execute: completion); return }
            self.session.startRunning()
            // Re-assert after start: some formats reset frame duration when the
            // session commits. Constant 30 fps is what post relies on.
            self.lockFrameRate()
            Log.write("session running: \(self.session.isRunning)")
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func configure() -> String? {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
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

        guard session.canAddOutput(movieOutput) else { return "Snimanje nije podržano" }
        session.addOutput(movieOutput)
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

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        Log.write("configured \(dims.width)x\(dims.height) \(format.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" })")
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

    func startRecording(to url: URL) {
        queue.async {
            guard self.session.isRunning, !self.movieOutput.isRecording else {
                Log.write("startRecording ignored (running \(self.session.isRunning), recording \(self.movieOutput.isRecording))")
                return
            }
            self.lockFrameRate()
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        queue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    func setScanning(_ on: Bool) {
        queue.async {
            let types: [AVMetadataObject.ObjectType] = on && self.metadataOutput.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
            self.metadataOutput.metadataObjectTypes = types
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = Date()
        DispatchQueue.main.async { self.onRecordingStarted?(fileURL, now) }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // AVFoundation reports some successful stops as errors; the file is usable
        // whenever this key says so.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        let realError = (finished == true) ? nil : error
        DispatchQueue.main.async { self.onRecordingFinished?(outputFileURL, realError) }
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
