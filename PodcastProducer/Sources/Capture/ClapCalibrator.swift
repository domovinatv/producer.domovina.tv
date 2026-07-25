import Foundation
import AVFoundation
import Accelerate
import CoreGraphics

/// Measures the camera's internal A/V offset — the one assumption the continuous
/// correlator cannot check itself.
///
/// The correlator measures the offset between the microphones and the camera's
/// HDMI *audio*. That equals the offset to the *picture* only if the camera emits
/// audio aligned with video over HDMI. Usually it does. If it doesn't, every take
/// is off by the same constant, and nothing on screen would reveal it.
///
/// A clap settles it, because sound and light leave the hands at the same instant
/// and from the same point in space. Detect the clap's transient in the HDMI audio,
/// identify the frame where the hands meet, and the difference is the constant:
///
///     N = audioTime − pictureTime          (stored as cameraAVOffsetMilliseconds)
///     micToPicture = correlatedOffset − N
///
/// Clap **close to the camera**: sound needs ~2.9 ms per metre, and that delay
/// lands squarely in the measurement. At 30 cm it is under a millisecond.
enum ClapCalibrator {

    enum CalibrationError: LocalizedError {
        case noAudioTrack
        case noVideoTrack
        case readerFailed(String)
        case noClapsFound

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "Snimka nema audio trag — je li HDMI zvuk bio odabran?"
            case .noVideoTrack: return "Snimka nema video trag."
            case .readerFailed(let reason): return "Čitanje snimke nije uspjelo: \(reason)"
            case .noClapsFound: return "Nije pronađen ni jedan pljesak. Pljesni jasnije i bliže kameri."
            }
        }
    }

    /// One detected transient, with sub-millisecond refinement.
    struct Clap: Identifiable, Equatable {
        var id: Int
        /// Seconds into the asset where the transient starts.
        var audioSeconds: Double
        /// Peak-to-local-median ratio. Higher is a cleaner clap.
        var sharpness: Double
    }

    struct FrameSample: Identifiable {
        var id: Int
        var seconds: Double
        var image: CGImage
    }

    // MARK: - Onset detection

    private static let analysisRate: Double = 48000
    /// 2 ms hops. A clap's attack is far shorter than this, so the hop only has to
    /// localise it well enough for the sample-level refinement that follows.
    private static let hopSeconds: Double = 0.002

    static func detectClaps(in url: URL, maxCount: Int = 4) async throws -> [Clap] {
        let samples = try await monoSamples(of: url)
        guard !samples.isEmpty else { throw CalibrationError.noAudioTrack }
        return detectClaps(in: samples, sampleRate: analysisRate, maxCount: maxCount)
    }

    /// Split out from the file reading so it can be exercised on synthetic signals.
    static func detectClaps(in samples: [Float],
                            sampleRate: Double,
                            maxCount: Int = 4) -> [Clap] {
        let hop = max(1, Int(hopSeconds * sampleRate))
        let hopCount = samples.count / hop
        guard hopCount > 8 else { return [] }

        // Short-time energy in dB, then its positive first difference: a clap is a
        // near-instantaneous rise, which this makes stand out from speech.
        var energy = [Float](repeating: 0, count: hopCount)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<hopCount {
                var meanSquare: Float = 0
                vDSP_measqv(base + index * hop, 1, &meanSquare, vDSP_Length(hop))
                energy[index] = 10 * log10f(max(meanSquare, 1e-12))
            }
        }

        var rise = [Float](repeating: 0, count: hopCount)
        for index in 1..<hopCount {
            rise[index] = max(0, energy[index] - energy[index - 1])
        }

        let median = robustMedian(rise)
        // A clap rises tens of dB in one hop; speech onsets rarely clear this.
        let threshold = max(6.0, Double(median) * 6.0)
        let minimumSpacing = Int(0.35 / hopSeconds)

        var candidates: [(index: Int, strength: Double)] = []
        var index = 1
        while index < hopCount {
            if Double(rise[index]) >= threshold {
                // Take the local maximum of the burst, not its first hop.
                var best = index
                var scan = index
                while scan < min(hopCount, index + minimumSpacing) {
                    if rise[scan] > rise[best] { best = scan }
                    scan += 1
                }
                candidates.append((best, Double(rise[best])))
                index = best + minimumSpacing
            } else {
                index += 1
            }
        }

        let strongest = candidates.sorted { $0.strength > $1.strength }.prefix(maxCount)
        let ordered = strongest.sorted { $0.index < $1.index }

        return ordered.enumerated().map { position, candidate in
            let refined = refineOnset(
                in: samples,
                aroundHop: candidate.index,
                hop: hop,
                sampleRate: sampleRate
            )
            return Clap(
                id: position,
                audioSeconds: refined,
                sharpness: candidate.strength / max(1.0, Double(median))
            )
        }
    }

    /// Walks back from the loud hop to the first sample that crosses a fraction of
    /// the burst's peak, which puts the timestamp on the attack rather than after it.
    private static func refineOnset(in samples: [Float],
                                    aroundHop hopIndex: Int,
                                    hop: Int,
                                    sampleRate: Double) -> Double {
        let searchStart = max(0, (hopIndex - 2) * hop)
        let searchEnd = min(samples.count, (hopIndex + 2) * hop)
        guard searchEnd > searchStart else { return Double(hopIndex * hop) / sampleRate }

        var peak: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_maxmgv(base + searchStart, 1, &peak, vDSP_Length(searchEnd - searchStart))
        }
        let crossing = peak * 0.2
        for index in searchStart..<searchEnd where abs(samples[index]) >= crossing {
            return Double(index) / sampleRate
        }
        return Double(hopIndex * hop) / sampleRate
    }

    private static func robustMedian(_ values: [Float]) -> Float {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    // MARK: - Audio extraction

    static func monoSamples(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CalibrationError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CalibrationError.readerFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: analysisRate,
            AVNumberOfChannelsKey: 1
        ])
        guard reader.canAdd(output) else {
            throw CalibrationError.readerFailed("izlaz nije prihvaćen")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CalibrationError.readerFailed(reader.error?.localizedDescription ?? "nepoznato")
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: raw.baseAddress!)
            }
            samples.append(contentsOf: data)
        }
        if reader.status == .failed {
            throw CalibrationError.readerFailed(reader.error?.localizedDescription ?? "nepoznato")
        }
        return samples
    }

    // MARK: - Frame extraction

    /// Frames spanning `±count/2` around `seconds`, so the exact contact frame can
    /// be picked by eye. Tolerances are zero because a neighbouring keyframe would
    /// defeat the entire measurement.
    static func frames(around seconds: Double,
                       in url: URL,
                       count: Int = 13) async throws -> [FrameSample] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CalibrationError.noVideoTrack
        }
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let fps = Double(nominalFrameRate > 0 ? nominalFrameRate : 30)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true

        var result: [FrameSample] = []
        let half = count / 2
        for step in -half...half {
            let target = seconds + Double(step) / fps
            guard target >= 0, target <= totalSeconds else { continue }
            let time = CMTime(seconds: target, preferredTimescale: 600)
            do {
                let (image, actual) = try await generator.image(at: time)
                result.append(
                    FrameSample(id: result.count,
                                seconds: CMTimeGetSeconds(actual),
                                image: image)
                )
            } catch {
                continue
            }
        }
        return result
    }

    /// Time of the largest frame-to-frame brightness jump in a window.
    ///
    /// Not used for clap calibration — a clap has no luminance signature. It exists
    /// so the calibration path can be verified end to end against a synthetic clip
    /// carrying a flash at a known offset from its click, without a human in the loop.
    static func brightnessJumpTime(around seconds: Double,
                                   in url: URL,
                                   count: Int = 13) async throws -> Double? {
        let samples = try await frames(around: seconds, in: url, count: count)
        guard samples.count > 1 else { return nil }

        let brightness = samples.map { averageBrightness(of: $0.image) }
        var bestIndex = 1
        var bestJump = -Double.greatestFiniteMagnitude
        for index in 1..<brightness.count {
            let jump = brightness[index] - brightness[index - 1]
            if jump > bestJump {
                bestJump = jump
                bestIndex = index
            }
        }
        return samples[bestIndex].seconds
    }

    private static func averageBrightness(of image: CGImage) -> Double {
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let total = pixels.reduce(0) { $0 + Int($1) }
        return Double(total) / Double(pixels.count)
    }

    // MARK: - Result

    /// Median of the per-clap measurements, for the same reason the sync offset uses
    /// a median: one misidentified frame should not move the constant.
    static func offsetMilliseconds(from measurements: [Double]) -> Double? {
        guard !measurements.isEmpty else { return nil }
        let sorted = measurements.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

/// Persisted camera A/V calibration constant.
enum CameraCalibrationStore {

    private static let key = "studio.cameraAVOffsetMilliseconds"
    private static let dateKey = "studio.cameraAVOffsetMeasuredAt"

    static var offsetMilliseconds: Double? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key)
    }

    static var measuredAt: Date? {
        UserDefaults.standard.object(forKey: dateKey) as? Date
    }

    static func save(_ milliseconds: Double) {
        UserDefaults.standard.set(milliseconds, forKey: key)
        UserDefaults.standard.set(Date(), forKey: dateKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: dateKey)
    }
}
