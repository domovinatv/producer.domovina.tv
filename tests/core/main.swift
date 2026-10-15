import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "✅ \(message)" : "❌ \(message)")
    if !condition { failures += 1 }
}

// ---------- HostClock ----------
let nowHost = mach_absolute_time()
let roundTrip = HostClock.hostTime(fromNanos: HostClock.nanos(fromHostTime: nowHost))
expect(abs(Int64(roundTrip) - Int64(nowHost)) <= 2, "HostClock nanos↔hostTime round-trip")
expect(HostClock.deltaMilliseconds(2_000_000_000, 1_000_000_000) == 1000, "delta pozitivna")
expect(HostClock.deltaMilliseconds(1_000_000_000, 2_000_000_000) == -1000, "delta negativna (bez UInt64 wrapa)")

// ---------- LevelMeter ----------
let meter = LevelMeter()
let sampleRate = 48000.0
var sine = [Float](repeating: 0, count: 4800)   // 0.1 s
for i in 0..<sine.count { sine[i] = 0.1 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) }
for _ in 0..<10 { sine.withUnsafeBufferPointer { meter.process(samples: $0.baseAddress!, count: sine.count, sampleRate: sampleRate) } }
let sineReading = meter.snapshot()
// 0.1 amplitude = -20 dBFS peak; a sine's RMS is peak/√2 = -23 dBFS.
expect(abs(sineReading.peakDB - (-20)) < 0.6, String(format: "peak ≈ -20 dBFS (dobiveno %.2f)", sineReading.peakDB))
expect(abs(sineReading.rmsDB - (-23)) < 0.8, String(format: "rms ≈ -23 dBFS (dobiveno %.2f)", sineReading.rmsDB))
expect(!sineReading.isSilent, "signal nije prijavljen kao tišina")

let clipMeter = LevelMeter()
var loud = [Float](repeating: 1.0, count: 480)
loud.withUnsafeBufferPointer { clipMeter.process(samples: $0.baseAddress!, count: loud.count, sampleRate: sampleRate) }
expect(clipMeter.snapshot().clipCount == 1, "clipping detektiran na 0 dBFS")
expect(clipMeter.snapshot().isClipping, "isClipping true")

let silentMeter = LevelMeter()
let quiet = [Float](repeating: 0, count: 48000)  // 1 s
for _ in 0..<20 { quiet.withUnsafeBufferPointer { silentMeter.process(samples: $0.baseAddress!, count: quiet.count, sampleRate: sampleRate) } }
expect(silentMeter.snapshot().isSilent, "mrtvi mikrofon detektiran nakon 20 s tišine")

// ---------- Multi-channel metering ----------
// The case that matters for a RODE Connect virtual device or two mics hard-panned
// L/R: channel 0 silent, channel 1 carrying the voice. Metering only channel 0
// would report a dead mic on a perfectly healthy input.
let stereoMeter = LevelMeter()
let frames = 4800
var left = [Float](repeating: 0, count: frames)                      // silent
var right = [Float](repeating: 0, count: frames)
for i in 0..<frames { right[i] = 0.5 * sinf(2 * .pi * 300 * Float(i) / Float(sampleRate)) }

for _ in 0..<10 {
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            var pointers = [l.baseAddress!, r.baseAddress!]
            pointers.withUnsafeMutableBufferPointer { channels in
                stereoMeter.process(channelData: channels.baseAddress!, channelCount: 2,
                                    frameCount: frames, sampleRate: sampleRate)
            }
        }
    }
}
let stereoReading = stereoMeter.snapshot()
// 0.5 amplitude = -6 dBFS peak, so the right channel must dominate the reading.
expect(abs(stereoReading.peakDB - (-6)) < 0.6,
       String(format: "stereo: peak s desnog kanala (%.2f dB, ocekivano -6)", stereoReading.peakDB))
expect(!stereoReading.isSilent, "stereo: NIJE prijavljen mrtvi mikrofon iako je lijevi kanal tih")

let leftOnlyMeter = LevelMeter()
for _ in 0..<10 {
    left.withUnsafeMutableBufferPointer { l in
        var pointers = [l.baseAddress!]
        pointers.withUnsafeMutableBufferPointer { channels in
            leftOnlyMeter.process(channelData: channels.baseAddress!, channelCount: 1,
                                  frameCount: frames, sampleRate: sampleRate)
        }
    }
}
expect(leftOnlyMeter.snapshot().rmsDB < -100, "mono tisina: i dalje prijavljena kao tisina")

// ---------- LipSyncMonitor: the real test ----------
// Same room audio into both feeds, but the camera side delayed by 100 ms.
// The correlator must report +100 ms (positive = camera lags the microphones).
func roomAudio(seconds: Double, rate: Double) -> [Float] {
    let count = Int(seconds * rate)
    var out = [Float](repeating: 0, count: count)
    var seed: UInt64 = 12345
    for i in 0..<count {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
        let t = Double(i) / rate
        // 250 ms bursts every 700 ms — speech-like onsets, easy to correlate.
        let gate: Float = fmod(t, 0.7) < 0.25 ? 1.0 : 0.02
        out[i] = noise * 0.5 * gate
    }
    return out
}

for delayMs in [0.0, 100.0, -60.0] {
    let monitor = LipSyncMonitor()
    let rate = 48000.0
    let base = roomAudio(seconds: 8, rate: rate)
    let shift = Int(abs(delayMs) / 1000.0 * rate)

    var camera = base
    if delayMs > 0 {
        camera = [Float](repeating: 0, count: shift) + base.dropLast(shift)
    } else if delayMs < 0 {
        camera = Array(base.dropFirst(shift)) + [Float](repeating: 0, count: shift)
    }

    let chunk = 4096
    var offset = 0
    while offset < base.count {
        let n = min(chunk, base.count - offset)
        base.withUnsafeBufferPointer { monitor.feedMicrophone(samples: $0.baseAddress! + offset, count: n, sampleRate: rate, hostNanos: 1_000_000_000) }
        camera.withUnsafeBufferPointer { monitor.feedCamera(samples: $0.baseAddress! + offset, count: n, sampleRate: rate, hostNanos: 1_000_000_000) }
        offset += n
    }
    monitor.recompute()
    let reading = monitor.snapshot()
    expect(reading.confidence > 0.5, String(format: "korelacija pouzdana za pomak %+.0f ms (%.2f)", delayMs, reading.confidence))
    expect(abs(reading.offsetMilliseconds - delayMs) <= 2,
           String(format: "izmjeren pomak %+.1f ms, očekivan %+.0f ms", reading.offsetMilliseconds, delayMs))
}

// ---------- Manifest ----------
var manifest = SessionManifest(
    sessionID: "test", title: "Test", createdAt: Date(),
    machine: .init(hostName: "h", osVersion: "o", appVersion: "1")
)
let anchor: UInt64 = 5_000_000_000
manifest.startedAtHostNanos = anchor
manifest.stoppedAtHostNanos = anchor + 3_600_000_000_000
manifest.upsert(track: .init(id: "mic-1", kind: .microphone, label: "A", deviceName: "d",
                             relativePath: "audio/mic-1.wav",
                             firstSampleHostNanos: anchor + 250_000_000))
manifest.upsert(track: .init(id: "mic-2", kind: .microphone, label: "B", deviceName: "d",
                             relativePath: "audio/mic-2.wav",
                             firstSampleHostNanos: anchor - 120_000_000))
expect(abs((manifest.track(withID: "mic-1")?.offsetSeconds(relativeTo: anchor) ?? 0) - 0.25) < 1e-9, "pozitivan offset")
expect(abs((manifest.track(withID: "mic-2")?.offsetSeconds(relativeTo: anchor) ?? 0) + 0.12) < 1e-9, "negativan offset (bez UInt64 wrapa)")
expect(abs((manifest.durationSeconds ?? 0) - 3600) < 1e-6, "trajanje 3600 s")

let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let data = try! encoder.encode(manifest)
let decoded = try! decoder.decode(SessionManifest.self, from: data)
expect(decoded.tracks.count == 2 && decoded.sessionID == "test", "manifest JSON round-trip")

// upsert replaces rather than duplicates
manifest.upsert(track: .init(id: "mic-1", kind: .microphone, label: "A2", deviceName: "d", relativePath: "x"))
expect(manifest.tracks.count == 2 && manifest.track(withID: "mic-1")?.label == "A2", "upsert zamjenjuje trag")

// ---------- SessionStore ----------
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("studio-test-\(UUID().uuidString)")
let store = try! SessionStore(libraryURL: tmp, title: "Đakovo: čćžšđ epizoda #42!!")
expect(FileManager.default.fileExists(atPath: store.manifestURL.path), "manifest zapisan na disk")
let slug = store.snapshot().sessionID
expect(slug.allSatisfy { $0.isASCII }, "naziv mape je čisti ASCII: \(slug)")
expect(slug.contains("dakovo") && slug.contains("cczsd"), "dijakritika transliterirana: \(slug)")
expect(!slug.contains("--") && !slug.hasSuffix("-"), "nema dvostrukih ni završnih crtica: \(slug)")
store.log("test događaj", level: .warning)
store.saveNow()
expect(store.snapshot().events.count == 1, "događaj zabilježen")
let reloaded = try! decoder.decode(SessionManifest.self, from: Data(contentsOf: store.manifestURL))
expect(reloaded.events.first?.message == "test događaj", "događaj preživio zapis na disk")
expect(store.relativePath(for: store.audioURL.appendingPathComponent("mic-1.wav")) == "audio/mic-1.wav", "relativna putanja")
try? FileManager.default.removeItem(at: tmp)


// ---------- Cloudflare dashboard URL parsing ----------
//
// The account ID is 32 hex characters nobody retypes correctly, so it is read
// from the address bar of the page the operator is already on.

func parsed(_ url: String) -> R2DashboardURL.Parsed? { R2DashboardURL.parse(url) }

let bucketURL = "https://dash.cloudflare.com/7dc7167b7e2e00923bfa7cd697df14e4/r2/default/buckets/domovina-tv-podcast-studio-storage/settings"
expect(parsed(bucketURL)?.accountID == "7dc7167b7e2e00923bfa7cd697df14e4", "account iz URL-a bucketa")
expect(parsed(bucketURL)?.bucket == "domovina-tv-podcast-studio-storage", "bucket iz URL-a")

// Bucket lives after the "buckets" marker, not at a fixed depth: the
// jurisdiction segment is "default" on most accounts but "eu" elsewhere.
expect(parsed("https://dash.cloudflare.com/7dc7167b7e2e00923bfa7cd697df14e4/r2/eu/buckets/moj-bucket")?.bucket == "moj-bucket",
       "jurisdikcija eu ne pomiče bucket")

// Pages that are not about one bucket still carry the account.
let overview = parsed("https://dash.cloudflare.com/7dc7167b7e2e00923bfa7cd697df14e4/r2/overview")
expect(overview?.accountID == "7dc7167b7e2e00923bfa7cd697df14e4" && overview?.bucket == nil,
       "overview daje account bez bucketa")

expect(parsed("dash.cloudflare.com/7dc7167b7e2e00923bfa7cd697df14e4/r2/overview") != nil,
       "radi i bez sheme, kako neki preglednici kopiraju")
expect(parsed("  " + bucketURL + "\n") != nil, "praznine oko zalijepljenog teksta se ignoriraju")

// Anything that is not a Cloudflare account URL must be refused rather than
// half-accepted — a wrong account ID fails much later, at upload time.
expect(parsed("https://example.com/7dc7167b7e2e00923bfa7cd697df14e4/r2/overview") == nil, "tuđi host odbijen")
expect(parsed("https://dash.cloudflare.com/nije-account/r2/overview") == nil, "neispravan account odbijen")
expect(parsed("https://dash.cloudflare.com/7DC7167B7E2E00923BFA7CD697DF14E4/r2/overview") == nil, "velika slova nisu account ID")
expect(parsed("") == nil, "prazan unos odbijen")

expect(R2DashboardURL.apiTokensPage(accountID: "7dc7167b7e2e00923bfa7cd697df14e4")?.absoluteString
       == "https://dash.cloudflare.com/7dc7167b7e2e00923bfa7cd697df14e4/r2/api-tokens",
       "link na stranicu s ključevima")

// The S3 secret is the SHA-256 of the token value — a pure function, so it is
// checkable against a known vector without touching the network.
expect(R2TokenCredentials.secretAccessKey(forToken: "abc") ==
       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
       "secret je SHA-256 tokena")
expect(R2TokenCredentials.secretAccessKey(forToken: "  abc\n") ==
       R2TokenCredentials.secretAccessKey(forToken: "abc"),
       "praznine oko tokena ne mijenjaju secret")

// ---------- Device enumeration ----------
let inputs = AudioDeviceEnumerator.inputDevices()
print("\nℹ️  CoreAudio ulazni uređaji (\(inputs.count)):")
for device in inputs { print("   • \(device.displayName)  [\(device.uid)]") }

print("")
print(failures == 0 ? "🏁 Svi core testovi prošli." : "🛑 \(failures) neuspješnih.")
exit(failures == 0 ? 0 : 1)
