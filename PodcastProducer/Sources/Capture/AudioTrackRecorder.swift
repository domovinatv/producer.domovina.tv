import Foundation
import AVFoundation
import CoreAudio

/// Records one microphone to its own isolated 24-bit WAV file.
///
/// Design rules that matter in a live take:
/// * The capture tap never touches the disk or the network — buffers are copied
///   and handed to a private serial queue.
/// * The host-clock timestamp of the first sample is captured and never
///   recalculated, because that number *is* the sync.
/// * A parallel stream of short segment files is produced for the R2 uploader,
///   so a machine that dies mid-take still has everything but the last segment
///   safely off-site.
final class AudioTrackRecorder {

    enum RecorderError: LocalizedError {
        case deviceUnavailable(String)
        case cannotSetDevice(OSStatus)
        case invalidFormat
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable(let name): return "Audio uređaj nije dostupan: \(name)"
            case .cannotSetDevice(let status): return "Ne mogu postaviti ulazni uređaj (OSStatus \(status))"
            case .invalidFormat: return "Uređaj javlja neispravan audio format"
            case .engineFailed(let reason): return "AVAudioEngine se nije pokrenuo: \(reason)"
            }
        }
    }

    struct Status {
        var isRunning = false
        var frameCount: UInt64 = 0
        var firstSampleHostNanos: UInt64?
        var measuredSampleRate: Double?
        var driftPPM: Double?
        var levels = LevelMeter.Reading()
        var segmentsWritten = 0
        var lastError: String?
    }

    let trackID: String
    let label: String
    let device: AudioInputDevice

    /// Length of each uploadable segment. 60 s of mono 24-bit/48 kHz is ~8.6 MB —
    /// comfortably a single R2 PUT, no multipart bookkeeping needed.
    var segmentSeconds: Double = 60

    /// Called on the writer queue when a segment file is closed and ready to upload.
    var onSegmentReady: ((URL, Int, UInt64, Double) -> Void)?
    /// Mono, downsampled samples for the lip-sync correlator.
    var onMonitorSamples: ((UnsafePointer<Float>, Int, Double, UInt64) -> Void)?

    private let engine = AVAudioEngine()
    private let meter = LevelMeter()
    private let writerQueue: DispatchQueue
    private let stateLock = NSLock()

    private let continuousURL: URL
    private let segmentsDirectory: URL
    private var continuousFile: AVAudioFile?
    private var segmentFile: AVAudioFile?
    private var segmentIndex = 0
    private var segmentFrameCount: AVAudioFramePosition = 0
    private var segmentStartHostNanos: UInt64 = 0
    private var fileSettings: [String: Any] = [:]

    private var status = Status()

    init(trackID: String, label: String, device: AudioInputDevice, audioDirectory: URL, segmentsDirectory: URL) {
        self.trackID = trackID
        self.label = label
        self.device = device
        self.continuousURL = audioDirectory.appendingPathComponent("\(trackID).wav")
        self.segmentsDirectory = segmentsDirectory.appendingPathComponent(trackID, isDirectory: true)
        self.writerQueue = DispatchQueue(label: "tv.domovina.studio.audio.\(trackID)", qos: .userInitiated)
    }

    var localFileURL: URL { continuousURL }

    func snapshot() -> Status {
        stateLock.lock()
        var copy = status
        stateLock.unlock()
        copy.levels = meter.snapshot()
        return copy
    }

    // MARK: - Lifecycle

    func start() throws {
        try FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)

        // Bind this engine instance to one specific HAL device. Touching
        // `inputNode` is what instantiates the underlying AUHAL unit, so the
        // property must be set after that and before the engine starts.
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw RecorderError.deviceUnavailable(device.name)
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw RecorderError.cannotSetDevice(status) }

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.invalidFormat }

        fileSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        continuousFile = try AVAudioFile(
            forWriting: continuousURL,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        meter.reset()
        stateLock.lock()
        self.status = Status(isRunning: true)
        stateLock.unlock()

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.handle(buffer: buffer, time: time, sampleRate: format.sampleRate)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            continuousFile = nil
            throw RecorderError.engineFailed(error.localizedDescription)
        }
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Drain the writer queue so the last buffers land before we close files.
        writerQueue.sync {
            self.closeCurrentSegment()
            self.continuousFile = nil
        }

        stateLock.lock()
        status.isRunning = false
        stateLock.unlock()
    }

    // MARK: - Capture path

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime, sampleRate: Double) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.floatChannelData else { return }

        let bufferHostNanos = time.isHostTimeValid
            ? HostClock.nanos(fromHostTime: time.hostTime)
            : HostClock.now()

        meter.process(samples: channelData[0], count: frameLength, sampleRate: sampleRate)
        onMonitorSamples?(channelData[0], frameLength, sampleRate, bufferHostNanos)

        guard let copy = AudioTrackRecorder.copy(buffer: buffer) else { return }

        stateLock.lock()
        if status.firstSampleHostNanos == nil {
            status.firstSampleHostNanos = bufferHostNanos
            segmentStartHostNanos = bufferHostNanos
        }
        // Measured rate = frames delivered *before* this buffer's timestamp,
        // divided by the host-clock time that elapsed to reach it. Counting the
        // current buffer's frames here would bias the result by one buffer
        // length (~24 ppm over an hour at 4096 frames), which is the same order
        // of magnitude as the drift we are trying to measure.
        if let first = status.firstSampleHostNanos, bufferHostNanos > first {
            let elapsed = Double(bufferHostNanos - first) / 1_000_000_000.0
            if elapsed > 20 {
                let measured = Double(status.frameCount) / elapsed
                status.measuredSampleRate = measured
                status.driftPPM = (measured / sampleRate - 1.0) * 1_000_000.0
            }
        }
        status.frameCount &+= UInt64(frameLength)
        status.levels = meter.snapshot()
        stateLock.unlock()

        writerQueue.async { [weak self] in
            self?.write(copy, hostNanos: bufferHostNanos, sampleRate: sampleRate)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, hostNanos: UInt64, sampleRate: Double) {
        do {
            try continuousFile?.write(from: buffer)
        } catch {
            stateLock.lock()
            status.lastError = "Zapis u \(continuousURL.lastPathComponent) nije uspio: \(error.localizedDescription)"
            stateLock.unlock()
        }

        if segmentFile == nil {
            openSegment(startingAt: hostNanos)
        }
        do {
            try segmentFile?.write(from: buffer)
            segmentFrameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // A failing segment must never take the continuous master with it.
            segmentFile = nil
        }

        if Double(segmentFrameCount) / sampleRate >= segmentSeconds {
            closeCurrentSegment()
        }
    }

    private func openSegment(startingAt hostNanos: UInt64) {
        let url = segmentsDirectory.appendingPathComponent(String(format: "%@-%05d.wav", trackID, segmentIndex))
        segmentFile = try? AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        segmentFrameCount = 0
        segmentStartHostNanos = hostNanos
    }

    private func closeCurrentSegment() {
        guard let file = segmentFile else { return }
        let url = file.url
        let sampleRate = file.fileFormat.sampleRate
        let duration = sampleRate > 0 ? Double(segmentFrameCount) / sampleRate : 0
        segmentFile = nil

        guard duration > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let index = segmentIndex
        segmentIndex += 1
        stateLock.lock()
        status.segmentsWritten = segmentIndex
        stateLock.unlock()

        onSegmentReady?(url, index, segmentStartHostNanos, duration)
    }

    // MARK: - Helpers

    /// Deep copy so the tap's buffer can be recycled immediately.
    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData,
              let destination = output.floatChannelData else { return nil }
        output.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(destination[channel], source[channel], bytes)
        }
        return output
    }
}
