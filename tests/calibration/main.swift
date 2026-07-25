import Foundation
import AVFoundation

// Verifies clap calibration end to end on a synthetic clip whose audio click and
// video flash sit at known, deliberately different times. The human step (picking
// the contact frame) is stood in for by the brightness-jump detector, so the audio
// detection, frame extraction and arithmetic are all the real code paths.
//
// Expected from the generator: click at 5.000 s, flash at 4.960 s → N = +40 ms.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("upotreba: calibration_test <clip.mov>")
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let expectedClickSeconds = 5.0
let expectedFlashSeconds = 4.96
let expectedOffsetMs = (expectedClickSeconds - expectedFlashSeconds) * 1000

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "✅ " : "❌ ") + message)
    if !condition { failures += 1 }
}

// --- synthetic signal first: detection without any file involved ---
do {
    let rate = 48000.0
    var samples = [Float](repeating: 0, count: Int(rate * 6))
    for index in 0..<samples.count {
        samples[index] = 0.02 * sinf(2 * .pi * 220 * Float(index) / Float(rate))
    }
    // Three claps at 1.0, 2.5 and 4.2 s.
    for onset in [1.0, 2.5, 4.2] {
        let start = Int(onset * rate)
        for offset in 0..<Int(0.03 * rate) {
            let decay = expf(-Float(offset) / Float(rate) * 150)
            samples[start + offset] += 0.9 * decay * sinf(2 * .pi * 3000 * Float(offset) / Float(rate))
        }
    }
    let claps = ClapCalibrator.detectClaps(in: samples, sampleRate: rate, maxCount: 4)
    expect(claps.count == 3, "sintetički signal: nađena 3 pljeska (nađeno \(claps.count))")
    let errors = zip(claps.map(\.audioSeconds), [1.0, 2.5, 4.2]).map { abs($0 - $1) * 1000 }
    if let worst = errors.max() {
        expect(worst < 2.0, String(format: "sintetički signal: najveća greška %.2f ms", worst))
    }
    // A steady tone with no transients must not produce phantom claps.
    var flat = [Float](repeating: 0, count: Int(rate * 4))
    for index in 0..<flat.count {
        flat[index] = 0.3 * sinf(2 * .pi * 440 * Float(index) / Float(rate))
    }
    let none = ClapCalibrator.detectClaps(in: flat, sampleRate: rate, maxCount: 4)
    expect(none.isEmpty, "čisti ton bez tranzijenata: nema lažnih pljeskova (nađeno \(none.count))")
}

// --- real asset: audio detection, frame extraction, and the constant ---
let claps = try await ClapCalibrator.detectClaps(in: url, maxCount: 4)
expect(claps.count == 1, "klip: nađen 1 pljesak (nađeno \(claps.count))")
guard let clap = claps.first else {
    print("🛑 bez pljeska nema smisla nastaviti.")
    exit(1)
}

let clickError = abs(clap.audioSeconds - expectedClickSeconds) * 1000
expect(clickError < 3.0,
       String(format: "klip: klik na %.4f s, očekivano %.3f s (greška %.2f ms)",
              clap.audioSeconds, expectedClickSeconds, clickError))
expect(clap.sharpness > 3, String(format: "klip: pljesak je oštar (%.1f×)", clap.sharpness))

let frames = try await ClapCalibrator.frames(around: clap.audioSeconds, in: url, count: 13)
expect(frames.count >= 11, "klip: izvučeno \(frames.count) frameova oko pljeska")

// Frames must be distinct instants, not the same keyframe returned repeatedly —
// a non-zero tolerance would silently ruin the whole measurement.
let unique = Set(frames.map { Int(($0.seconds * 1000).rounded()) })
expect(unique.count == frames.count,
       "klip: svaki frame je različit trenutak (\(unique.count)/\(frames.count))")

guard let flashSeconds = try await ClapCalibrator.brightnessJumpTime(around: clap.audioSeconds, in: url) else {
    print("❌ blic nije pronađen")
    exit(1)
}
let flashError = abs(flashSeconds - expectedFlashSeconds) * 1000
expect(flashError < 25.0,
       String(format: "klip: blic na %.4f s, očekivano %.3f s (greška %.2f ms)",
              flashSeconds, expectedFlashSeconds, flashError))

let measured = (clap.audioSeconds - flashSeconds) * 1000
let offsetError = abs(measured - expectedOffsetMs)
expect(offsetError < 25.0,
       String(format: "izmjeren N = %+.1f ms, očekivano %+.1f ms (greška %.1f ms)",
              measured, expectedOffsetMs, offsetError))

// Median, not mean: one misread frame must not move the constant.
// sorted: [-380, 39, 40, 40.5, 41] → middle is 40.0, and the outlier is ignored.
let median = ClapCalibrator.offsetMilliseconds(from: [40.0, 41.0, -380.0, 39.0, 40.5])
expect(median != nil && abs(median! - 40.0) < 0.01,
       "medijan ignorira promašeni frame (\(median.map { String(format: "%.1f", $0) } ?? "nil"))")
let evenMedian = ClapCalibrator.offsetMilliseconds(from: [40.0, 41.0, -380.0, 42.0])
expect(evenMedian != nil && abs(evenMedian! - 40.5) < 0.01,
       "paran broj mjerenja: prosjek dva srednja (\(evenMedian.map { String(format: "%.1f", $0) } ?? "nil"))")
expect(ClapCalibrator.offsetMilliseconds(from: []) == nil, "bez mjerenja nema konstante")

print("")
if failures > 0 {
    print("🛑 \(failures) neuspješnih.")
    exit(1)
}
print("🏁 Svi kalibracijski testovi prošli.")
