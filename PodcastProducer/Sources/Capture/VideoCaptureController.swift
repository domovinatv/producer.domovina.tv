import Foundation
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// Captures the Lumix GH5 over the Elgato 4K X (a class-compliant UVC device,
/// so no vendor driver is involved) and writes two things at once:
///
/// 1. `master` — a local high-quality proxy in a `.mov`, written with a movie
///    fragment interval so a crash still leaves a playable file.
/// 2. `segments` — low-bitrate fragmented MP4 chunks handed straight to the R2
///    uploader, so an off-site copy exists while you are still recording.
///
/// The camera's own SD-card recording remains the real master; this capture is
/// the timing reference that lets post align it exactly.
final class VideoCaptureController: NSObject {

    enum CaptureError: LocalizedError {
        case noVideoDevice
        case cannotAddInput(String)
        case writerSetupFailed(String)
        case permissionDenied(String)

        var errorDescription: String? {
            switch self {
            case .noVideoDevice: return "Nije pronađen video uređaj (Elgato). Provjeri USB kabel."
            case .cannotAddInput(let name): return "Ne mogu dodati ulaz u capture sesiju: \(name)"
            case .writerSetupFailed(let reason): return "Priprema snimanja videa nije uspjela: \(reason)"
            case .permissionDenied(let kind): return "macOS je odbio pristup \(kind). Postavke → Privatnost i sigurnost."
            }
        }
    }

    enum MasterCodec: String, CaseIterable, Identifiable {
        case hevc
        case proRes422Proxy
        case proRes422LT

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hevc: return "HEVC (najmanji fajl)"
            case .proRes422Proxy: return "ProRes 422 Proxy (hardverski)"
            case .proRes422LT: return "ProRes 422 LT (najbolji proxy)"
            }
        }

        var avCodec: AVVideoCodecType {
            switch self {
            case .hevc: return .hevc
            case .proRes422Proxy: return .proRes422Proxy
            case .proRes422LT: return .proRes422LT
            }
        }

        var approximateGigabytesPerHour: Double {
            switch self {
            case .hevc: return 9
            case .proRes422Proxy: return 20
            case .proRes422LT: return 45
            }
        }
    }

    struct Status {
        var isSessionRunning = false
        var isRecording = false
        var videoFrameCount: UInt64 = 0
        var audioFrameCount: UInt64 = 0
        var droppedFrameCount: UInt64 = 0
        var firstVideoHostNanos: UInt64?
        var lastVideoHostNanos: UInt64?
        var width = 0
        var height = 0
        var nominalFrameRate: Double = 0
        var segmentsWritten = 0
        var lastError: String?
    }

    // MARK: - Configuration

    var masterCodec: MasterCodec = .hevc
    /// Bitrate for the chunks that stream to R2 while recording. 3 Mbps at
    /// 1080p is watchable and fits comfortably on a normal upload link.
    var uploadTierBitrate = 3_000_000
    var uploadSegmentSeconds: Double = 6
    var maxCaptureHeight = 2160

    /// Fired on the writer queue when an fMP4 chunk is ready to upload.
    /// The `isInitialization` flag marks the very first chunk, which carries the
    /// moov box: without it the media chunks are undecodable, so recovery has to
    /// know which one it is.
    var onSegmentReady: ((Data, Int, UInt64, Bool) -> Void)?
    /// Mono camera-side samples for the lip-sync correlator.
    var onMonitorSamples: ((UnsafePointer<Float>, Int, Double, UInt64) -> Void)?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "tv.domovina.studio.capture.session")
    private let videoQueue = DispatchQueue(label: "tv.domovina.studio.capture.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "tv.domovina.studio.capture.audio", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "tv.domovina.studio.capture.writer", qos: .userInitiated)
    private let stateLock = NSLock()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private var masterWriter: AVAssetWriter?
    private var masterVideoInput: AVAssetWriterInput?
    private var masterAudioInput: AVAssetWriterInput?

    private var segmentWriter: AVAssetWriter?
    private var segmentVideoInput: AVAssetWriterInput?
    private var segmentAudioInput: AVAssetWriterInput?
    private var segmentIndex = 0
    private var segmentStartHostNanos: UInt64 = 0

    private var sessionStarted = false
    private var masterURL: URL?
    private var status = Status()
    private var monitorScratch = [Float](repeating: 0, count: 16384)

    func snapshot() -> Status {
        stateLock.lock()
        defer { stateLock.unlock() }
        return status
    }

    var masterFileURL: URL? { masterURL }

    // MARK: - Device discovery

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func requestPermissions() async throws {
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CaptureError.permissionDenied("kameri")
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw CaptureError.permissionDenied("mikrofonu")
            }
        }
    }

    // MARK: - Session lifecycle

    func startSession(videoDeviceID: String, audioDeviceID: String?) throws {
        guard let videoDevice = AVCaptureDevice(uniqueID: videoDeviceID) else {
            throw CaptureError.noVideoDevice
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        configureBestFormat(on: videoDevice)

        let newVideoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(newVideoInput) else { throw CaptureError.cannotAddInput(videoDevice.localizedName) }
        session.addInput(newVideoInput)
        videoInput = newVideoInput

        if let audioDeviceID, let audioDevice = AVCaptureDevice(uniqueID: audioDeviceID) {
            let newAudioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(newAudioInput) {
                session.addInput(newAudioInput)
                audioInput = newAudioInput
            }
        }

        // Keeping late frames means we never silently drop footage; the encode
        // path is hardware-backed so appends stay well ahead of capture.
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddInput("video output") }
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
        let frameRate = 1.0 / CMTimeGetSeconds(videoDevice.activeVideoMinFrameDuration)

        stateLock.lock()
        status.width = Int(dimensions.width)
        status.height = Int(dimensions.height)
        status.nominalFrameRate = frameRate.isFinite ? frameRate : 0
        stateLock.unlock()

        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        stateLock.lock()
        status.isSessionRunning = true
        stateLock.unlock()
    }

    func stopSession() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        stateLock.lock()
        status.isSessionRunning = false
        stateLock.unlock()
    }

    /// Picks the largest format under the configured height cap, preferring the
    /// highest frame rate available at that size.
    private func configureBestFormat(on device: AVCaptureDevice) {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dimensions.height) <= maxCaptureHeight
        }
        guard let best = candidates.max(by: { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lPixels = Int(l.width) * Int(l.height)
            let rPixels = Int(r.width) * Int(r.height)
            if lPixels != rPixels { return lPixels < rPixels }
            let lFPS = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rFPS = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return lFPS < rFPS
        }) else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            stateLock.lock()
            status.lastError = "Ne mogu zaključati format uređaja: \(error.localizedDescription)"
            stateLock.unlock()
        }
    }

    // MARK: - Recording

    func startRecording(masterURL url: URL) throws {
        try writerQueue.sync {
            try setUpMasterWriter(url: url)
            setUpSegmentWriter()
            sessionStarted = false
            segmentIndex = 0
            masterURL = url
        }
        stateLock.lock()
        status.isRecording = true
        status.videoFrameCount = 0
        status.audioFrameCount = 0
        status.droppedFrameCount = 0
        status.firstVideoHostNanos = nil
        stateLock.unlock()
    }

    func stopRecording() async {
        let master = writerQueue.sync { () -> AVAssetWriter? in
            masterVideoInput?.markAsFinished()
            masterAudioInput?.markAsFinished()
            segmentVideoInput?.markAsFinished()
            segmentAudioInput?.markAsFinished()
            return masterWriter
        }

        if let segmentWriter, segmentWriter.status == .writing {
            await segmentWriter.finishWriting()
        }
        if let master, master.status == .writing {
            await master.finishWriting()
        }

        writerQueue.sync {
            masterWriter = nil
            masterVideoInput = nil
            masterAudioInput = nil
            segmentWriter = nil
            segmentVideoInput = nil
            segmentAudioInput = nil
        }

        markRecordingStopped()
    }

    /// Locking is kept out of the async context on purpose — NSLock is not
    /// safe to hold across a suspension point.
    private func markRecordingStopped() {
        stateLock.lock()
        status.isRecording = false
        stateLock.unlock()
    }

    private func setUpMasterWriter(url: URL) throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw CaptureError.writerSetupFailed(error.localizedDescription)
        }

        // With fragments on disk every two seconds, a hard crash costs at most
        // the last fragment instead of the whole take.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let dimensions = currentDimensions()
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: masterCodec.avCodec,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height
        ]
        if masterCodec == .hevc {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate(for: dimensions),
                AVVideoExpectedSourceFrameRateKey: Int(snapshot().nominalFrameRate.rounded())
            ]
        }

        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoWriterInput) else {
            throw CaptureError.writerSetupFailed("kodek \(masterCodec.displayName) nije prihvaćen")
        }
        writer.add(videoWriterInput)

        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ])
        audioWriterInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioWriterInput) { writer.add(audioWriterInput) }

        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "nepoznat razlog")
        }

        masterWriter = writer
        masterVideoInput = videoWriterInput
        masterAudioInput = audioWriterInput
    }

    /// Optional second writer. If it cannot be created we still record locally —
    /// the cloud copy is a bonus, never a precondition for the take.
    private func setUpSegmentWriter() {
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: uploadSegmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let dimensions = currentDimensions()
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: uploadTierBitrate,
                AVVideoExpectedSourceFrameRateKey: Int(snapshot().nominalFrameRate.rounded())
            ]
        ])
        videoWriterInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoWriterInput) else { return }
        writer.add(videoWriterInput)

        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000
        ])
        audioWriterInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioWriterInput) { writer.add(audioWriterInput) }

        guard writer.startWriting() else { return }

        segmentWriter = writer
        segmentVideoInput = videoWriterInput
        segmentAudioInput = audioWriterInput
    }

    /// Falls back as a matched pair — mixing a real width with a default height
    /// would hand the encoder a wrong aspect ratio.
    private func currentDimensions() -> (width: Int, height: Int) {
        let snapshot = self.snapshot()
        guard snapshot.width > 0, snapshot.height > 0 else { return (1920, 1080) }
        return (snapshot.width, snapshot.height)
    }

    private func bitrate(for dimensions: (width: Int, height: Int)) -> Int {
        let pixels = dimensions.width * dimensions.height
        // ~0.1 bits per pixel per frame at 30fps, doubled for 4K headroom.
        return pixels >= 3_000_000 ? 60_000_000 : 20_000_000
    }
}

// MARK: - Sample buffer delegates

extension VideoCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostNanos = HostClock.nanos(fromCaptureTime: presentationTime)
        let isVideo = output === videoOutput

        if !isVideo {
            forwardAudioForMonitoring(sampleBuffer, hostNanos: hostNanos)
        }

        writerQueue.async { [weak self] in
            guard let self, let writer = self.masterWriter, writer.status == .writing else { return }

            // The session start time is taken from the first video frame so the
            // master and the upload segments share one timeline.
            if !self.sessionStarted {
                guard isVideo else { return }
                writer.startSession(atSourceTime: presentationTime)
                self.segmentWriter?.startSession(atSourceTime: presentationTime)
                self.segmentStartHostNanos = hostNanos
                self.sessionStarted = true
                self.stateLock.lock()
                self.status.firstVideoHostNanos = hostNanos
                self.stateLock.unlock()
            }

            if isVideo {
                if let input = self.masterVideoInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
                if let input = self.segmentVideoInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
                self.stateLock.lock()
                self.status.videoFrameCount &+= 1
                self.status.lastVideoHostNanos = hostNanos
                if writer.status == .failed {
                    self.status.lastError = writer.error?.localizedDescription
                }
                self.stateLock.unlock()
            } else {
                if let input = self.masterAudioInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
                if let input = self.segmentAudioInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
                self.stateLock.lock()
                self.status.audioFrameCount &+= 1
                self.stateLock.unlock()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        stateLock.lock()
        status.droppedFrameCount &+= 1
        stateLock.unlock()
    }

    /// Pulls a mono float copy of the HDMI-embedded camera audio for the
    /// lip-sync correlator without disturbing the recording path.
    private func forwardAudioForMonitoring(_ sampleBuffer: CMSampleBuffer, hostNanos: UInt64) {
        guard onMonitorSamples != nil,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return }
        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        var blockBuffer: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * 8
        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listMemory.deallocate() }
        let listPointer = listMemory.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let list = UnsafeMutableAudioBufferListPointer(listPointer)
        guard let first = list.first, let data = first.mData else { return }

        let channels = Int(first.mNumberChannels)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let count = min(frameCount, monitorScratch.count)

        if isFloat {
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<count { monitorScratch[index] = samples[index * channels] }
        } else if asbd.mBitsPerChannel == 16 {
            let samples = data.assumingMemoryBound(to: Int16.self)
            for index in 0..<count { monitorScratch[index] = Float(samples[index * channels]) / 32768.0 }
        } else {
            return
        }

        monitorScratch.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            onMonitorSamples?(base, count, asbd.mSampleRate, hostNanos)
        }
    }
}

// MARK: - Segment delegate

extension VideoCaptureController: AVAssetWriterDelegate {

    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        let index = segmentIndex
        segmentIndex += 1
        stateLock.lock()
        status.segmentsWritten = segmentIndex
        stateLock.unlock()
        onSegmentReady?(segmentData, index, segmentStartHostNanos, segmentType == .initialization)
    }
}
