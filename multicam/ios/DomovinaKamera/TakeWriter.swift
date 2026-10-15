import AVFoundation

/// Writes one take with AVAssetWriter from capture sample buffers.
///
/// The file's timeline starts at the first video frame: `startSession(atSourceTime:)`
/// is called with that frame's PTS and the frame is written at 0, so
/// `fileZeroSourceTime` *is* the source-clock time of PTS 0 — no estimate. Audio
/// from before that frame is dropped. Frame reordering is off, so PTS = DTS and the
/// video track has no composition offset or edit that could shift frame 0.
///
/// Not thread-safe by design: every call must come from the one serial queue the
/// capture outputs deliver on.
final class TakeWriter {

    enum Phase { case armed, writing, finishing, done }

    struct Stats {
        var videoFrames = 0
        var audioBuffers = 0
        var videoDroppedNotReady = 0
        var audioDroppedBeforeStart = 0
        var audioDroppedNotReady = 0
    }

    enum WriterError: LocalizedError {
        case notStarted
        case cannotAdd(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notStarted: return "Snimanje nije krenulo"
            case .cannotAdd(let what): return "Writer ne prima \(what)"
            case .failed(let why): return "Writer: \(why)"
            }
        }
    }

    let url: URL
    /// Source-clock time at which the first frame may be taken (scheduled start).
    let startAt: CMTime
    private(set) var phase: Phase = .armed
    private(set) var fileZeroSourceTime: CMTime?
    private(set) var stats = Stats()
    private var lastVideoPTS: CMTime?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    static let frameDuration = CMTime(value: 1, timescale: 30)

    static func videoSettings(codec: AVVideoCodecType, width: Int = 1920, height: Int = 1080) -> [String: Any] {
        [AVVideoCodecKey: codec,
         AVVideoWidthKey: width,
         AVVideoHeightKey: height,
         AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 16_000_000,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 30,
            AVVideoAllowFrameReorderingKey: false,
         ] as [String: Any]]
    }

    static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
    ]

    /// Creates the file and starts writing; the session itself starts on the first
    /// video frame at or after `startAt`.
    init(url: URL, videoSettings: [String: Any], audioSettings: [String: Any]?, startAt: CMTime) throws {
        self.url = url
        self.startAt = startAt
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // 600 = a common multiple of 30 fps: frames land on exact 1/30 s steps
        // (sub-ms rounding of capture jitter), so the file reads as constant 30 fps.
        writer.movieTimeScale = 600
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.mediaTimeScale = 600
        guard writer.canAdd(videoInput) else { throw WriterError.cannotAdd("video") }
        writer.add(videoInput)
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw WriterError.cannotAdd("audio") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
        guard writer.startWriting() else {
            throw WriterError.failed(writer.error?.localizedDescription ?? "startWriting")
        }
    }

    var isReadyForVideo: Bool { videoInput.isReadyForMoreMediaData }
    var isReadyForAudio: Bool { audioInput?.isReadyForMoreMediaData ?? true }

    var failure: Error? {
        writer.status == .failed ? (writer.error ?? WriterError.failed("status failed")) : nil
    }

    /// Returns true for the frame that started the file.
    @discardableResult
    func appendVideo(_ buffer: CMSampleBuffer) -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        var started = false
        switch phase {
        case .armed:
            // Only start on a frame that will actually be written, so frame 0 is at 0.
            guard CMTimeCompare(pts, startAt) >= 0, videoInput.isReadyForMoreMediaData,
                  writer.status == .writing else { return false }
            writer.startSession(atSourceTime: pts)
            fileZeroSourceTime = pts
            phase = .writing
            started = true
        case .writing:
            break
        case .finishing, .done:
            return false
        }
        guard writer.status == .writing else { return started }
        if let last = lastVideoPTS, CMTimeCompare(pts, last) <= 0 { return started }
        if videoInput.isReadyForMoreMediaData {
            if videoInput.append(buffer) {
                stats.videoFrames += 1
                lastVideoPTS = pts
            }
        } else {
            stats.videoDroppedNotReady += 1
        }
        return started
    }

    func appendAudio(_ buffer: CMSampleBuffer) {
        guard let audioInput, phase == .writing, let zero = fileZeroSourceTime, writer.status == .writing else {
            if phase == .armed { stats.audioDroppedBeforeStart += 1 }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard CMTimeCompare(pts, zero) >= 0 else { stats.audioDroppedBeforeStart += 1; return }
        if audioInput.isReadyForMoreMediaData {
            if audioInput.append(buffer) { stats.audioBuffers += 1 }
        } else {
            stats.audioDroppedNotReady += 1
        }
    }

    /// Finishes the file (or discards it if no frame was ever written). The
    /// completion runs on an arbitrary queue, once.
    func finish(completion: @escaping (Error?) -> Void) {
        switch phase {
        case .armed:
            phase = .done
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(WriterError.notStarted)
        case .writing:
            phase = .finishing
            guard writer.status == .writing else {
                // A failed writer cannot be finished; report why it failed.
                completion(failure ?? WriterError.failed("status \(writer.status.rawValue)"))
                return
            }
            if let last = lastVideoPTS {
                // End exactly one frame after the last picture; audio past it is trimmed.
                writer.endSession(atSourceTime: CMTimeAdd(last, Self.frameDuration))
            }
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            let writer = self.writer
            writer.finishWriting {
                completion(writer.status == .completed ? nil
                           : (writer.error ?? WriterError.failed("status \(writer.status.rawValue)")))
            }
        case .finishing, .done:
            break
        }
    }
}
