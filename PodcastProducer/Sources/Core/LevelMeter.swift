import Foundation
import Accelerate

/// Peak/RMS meter with broadcast-style ballistics plus the two things that
/// actually save a podcast: clip counting and dead-mic detection.
final class LevelMeter {

    struct Reading: Equatable {
        var peakDB: Float = -120
        var rmsDB: Float = -120
        var peakHoldDB: Float = -120
        var clipCount: Int = 0
        /// Seconds of continuous near-silence. A live mic that goes quiet for
        /// 15+ seconds usually means a dead USB link, not a thoughtful pause.
        var silentSeconds: Double = 0

        var isClipping: Bool { peakDB > -0.5 }
        var isSilent: Bool { silentSeconds > 15 }
    }

    private let lock = NSLock()
    private var reading = Reading()
    private var peakHoldExpiry: Double = 0
    private let silenceThresholdDB: Float = -50

    /// Feeds one channel of de-interleaved float samples.
    func process(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0 else { return }

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))

        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(count))

        let peakDB = amplitudeToDB(peak)
        let rmsDB = amplitudeToDB(sqrt(meanSquare))
        let chunkSeconds = Double(count) / sampleRate

        lock.lock()
        defer { lock.unlock() }

        // Fast attack, slow release so the meter is readable on a glance.
        reading.peakDB = peakDB > reading.peakDB ? peakDB : max(peakDB, reading.peakDB - Float(chunkSeconds) * 60)
        reading.rmsDB = rmsDB > reading.rmsDB ? rmsDB : max(rmsDB, reading.rmsDB - Float(chunkSeconds) * 30)

        if peakDB >= reading.peakHoldDB || peakHoldExpiry <= 0 {
            reading.peakHoldDB = max(peakDB, reading.peakHoldDB)
            peakHoldExpiry = 2.0
        } else {
            peakHoldExpiry -= chunkSeconds
            if peakHoldExpiry <= 0 { reading.peakHoldDB = peakDB }
        }

        // Anything at or above 0 dBFS is a hard clip on the way to the file.
        if peak >= 0.999 { reading.clipCount += 1 }

        if rmsDB < silenceThresholdDB {
            reading.silentSeconds += chunkSeconds
        } else {
            reading.silentSeconds = 0
        }
    }

    func snapshot() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        reading = Reading()
        peakHoldExpiry = 0
    }

    private func amplitudeToDB(_ amplitude: Float) -> Float {
        amplitude <= 0.0000001 ? -120 : max(-120, 20 * log10f(amplitude))
    }
}
