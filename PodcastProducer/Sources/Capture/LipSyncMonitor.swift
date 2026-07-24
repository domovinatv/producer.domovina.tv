import Foundation
import Accelerate

/// Live lip-sync confidence meter.
///
/// The host-clock timestamps already give a mathematically exact offset. This
/// monitor is the independent second opinion: it correlates the amplitude
/// envelope of the microphone mix against the camera's HDMI-embedded audio and
/// reports the measured A/V offset in milliseconds. If the two disagree, the
/// number on screen tells you *before* the guest leaves, not in the edit.
///
/// Correlating envelopes at 1 kHz instead of raw waveforms at 48 kHz costs
/// almost nothing and is more robust to the tonal difference between a PodMic
/// and the GH5's on-board microphone.
/// All mutable state is guarded by `lock`, so crossing threads is safe.
final class LipSyncMonitor: @unchecked Sendable {

    struct Reading: Equatable {
        /// Positive means camera audio lags behind the microphones.
        var offsetMilliseconds: Double = 0
        /// Normalised correlation peak, 0...1. Below ~0.3 the number is noise.
        var confidence: Double = 0
        /// Offset computed purely from host-clock timestamps.
        var clockOffsetMilliseconds: Double = 0
        var isValid: Bool { confidence > 0.3 }

        var agreesWithClock: Bool {
            isValid && abs(offsetMilliseconds - clockOffsetMilliseconds) < 40
        }
    }

    /// Envelope rate. 1 ms resolution is far finer than the ~20 ms threshold
    /// where humans start noticing lip-sync error.
    private let envelopeRate: Double = 1000
    private let windowSeconds: Double = 6
    private let maxLagSeconds: Double = 0.5

    private lazy var capacity = Int(envelopeRate * windowSeconds)
    private lazy var maxLag = Int(envelopeRate * maxLagSeconds)

    private var micEnvelope: [Float]
    private var cameraEnvelope: [Float]
    private var micWriteIndex = 0
    private var cameraWriteIndex = 0
    private var micAccumulator: Float = 0
    private var cameraAccumulator: Float = 0
    private var micAccumulatorCount = 0
    private var cameraAccumulatorCount = 0
    private var micFirstHostNanos: UInt64?
    private var cameraFirstHostNanos: UInt64?

    private let lock = NSLock()
    private var reading = Reading()

    init() {
        let size = Int(1000 * 6)
        micEnvelope = [Float](repeating: 0, count: size)
        cameraEnvelope = [Float](repeating: 0, count: size)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        micEnvelope = [Float](repeating: 0, count: capacity)
        cameraEnvelope = [Float](repeating: 0, count: capacity)
        micWriteIndex = 0
        cameraWriteIndex = 0
        micFirstHostNanos = nil
        cameraFirstHostNanos = nil
        reading = Reading()
    }

    func feedMicrophone(samples: UnsafePointer<Float>, count: Int, sampleRate: Double, hostNanos: UInt64) {
        lock.lock()
        if micFirstHostNanos == nil { micFirstHostNanos = hostNanos }
        appendEnvelope(
            samples: samples, count: count, sampleRate: sampleRate,
            buffer: &micEnvelope, writeIndex: &micWriteIndex,
            accumulator: &micAccumulator, accumulatorCount: &micAccumulatorCount
        )
        lock.unlock()
    }

    func feedCamera(samples: UnsafePointer<Float>, count: Int, sampleRate: Double, hostNanos: UInt64) {
        lock.lock()
        if cameraFirstHostNanos == nil { cameraFirstHostNanos = hostNanos }
        appendEnvelope(
            samples: samples, count: count, sampleRate: sampleRate,
            buffer: &cameraEnvelope, writeIndex: &cameraWriteIndex,
            accumulator: &cameraAccumulator, accumulatorCount: &cameraAccumulatorCount
        )
        lock.unlock()
    }

    func snapshot() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    /// Run this off the capture threads — roughly once per second is plenty.
    func recompute() {
        lock.lock()
        let mic = orderedBuffer(micEnvelope, writeIndex: micWriteIndex)
        let camera = orderedBuffer(cameraEnvelope, writeIndex: cameraWriteIndex)
        let micStart = micFirstHostNanos
        let cameraStart = cameraFirstHostNanos
        lock.unlock()

        var result = Reading()
        if let micStart, let cameraStart {
            result.clockOffsetMilliseconds = HostClock.deltaMilliseconds(cameraStart, micStart)
        }

        if let correlation = Self.bestLag(reference: mic, target: camera, maxLag: maxLag) {
            result.offsetMilliseconds = Double(correlation.lag) / envelopeRate * 1000.0
            result.confidence = Double(correlation.score)
        }

        lock.lock()
        reading = result
        lock.unlock()
    }

    // MARK: - Envelope building

    private func appendEnvelope(samples: UnsafePointer<Float>,
                                count: Int,
                                sampleRate: Double,
                                buffer: inout [Float],
                                writeIndex: inout Int,
                                accumulator: inout Float,
                                accumulatorCount: inout Int) {
        guard sampleRate > 0 else { return }
        let samplesPerEnvelopePoint = max(1, Int(sampleRate / envelopeRate))

        for index in 0..<count {
            accumulator += abs(samples[index])
            accumulatorCount += 1
            if accumulatorCount >= samplesPerEnvelopePoint {
                buffer[writeIndex] = accumulator / Float(accumulatorCount)
                writeIndex = (writeIndex + 1) % buffer.count
                accumulator = 0
                accumulatorCount = 0
            }
        }
    }

    private func orderedBuffer(_ buffer: [Float], writeIndex: Int) -> [Float] {
        guard writeIndex > 0, writeIndex <= buffer.count else { return buffer }
        return Array(buffer[writeIndex...]) + Array(buffer[..<writeIndex])
    }

    // MARK: - Correlation

    /// Normalised cross-correlation over a bounded lag range. Returns the lag in
    /// envelope points (positive = target lags the reference) and a 0...1 score.
    static func bestLag(reference: [Float], target: [Float], maxLag: Int) -> (lag: Int, score: Float)? {
        let usableLength = min(reference.count, target.count) - 2 * maxLag
        guard usableLength > 64 else { return nil }

        var referenceWindow = Array(reference[maxLag..<(maxLag + usableLength)])
        removeMean(&referenceWindow)
        var referenceEnergy: Float = 0
        vDSP_svesq(referenceWindow, 1, &referenceEnergy, vDSP_Length(usableLength))
        guard referenceEnergy > 1e-9 else { return nil }

        var bestScore: Float = -1
        var bestLag = 0

        for lag in -maxLag...maxLag {
            let start = maxLag + lag
            guard start >= 0, start + usableLength <= target.count else { continue }
            var targetWindow = Array(target[start..<(start + usableLength)])
            removeMean(&targetWindow)

            var targetEnergy: Float = 0
            vDSP_svesq(targetWindow, 1, &targetEnergy, vDSP_Length(usableLength))
            guard targetEnergy > 1e-9 else { continue }

            var dotProduct: Float = 0
            vDSP_dotpr(referenceWindow, 1, targetWindow, 1, &dotProduct, vDSP_Length(usableLength))

            let score = dotProduct / sqrt(referenceEnergy * targetEnergy)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        guard bestScore > 0 else { return nil }
        return (bestLag, bestScore)
    }

    private static func removeMean(_ values: inout [Float]) {
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        var negativeMean = -mean
        vDSP_vsadd(values, 1, &negativeMean, &values, 1, vDSP_Length(values.count))
    }
}
