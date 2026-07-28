import Foundation
import AVFoundation
import CoreAudio

//
// main.swift — end-to-end test na stvarnom hardveru.
//
// Za razliku od ostalih testova u `tests/`, ovaj namjerno dira hardver: otvara
// oba RØDE PodMic USB uređaja, Elgato capture, snima pravu sesiju na disk i
// provjeri što je od nje ostalo. Vozi pravi `StudioViewModel`, ne kopiju
// njegove logike — inače bi test prolazio dok aplikacija ne radi.
//
// Sinkronizacija se ne može izmjeriti u tihoj sobi, pa test sam proizvede zvuk:
// niz šumnih udara kroz zvučnike Maca, koje čuju i mikrofoni i interni mikrofon
// kamere (preko HDMI-ja). Razmaci su nepravilni namjerno — pravilan ritam daje
// korelatoru više jednakih vrhova i lag postaje višeznačan.
//

// MARK: - Nadomjestak za App/PodcastProducerApp.swift

/// Pravi `RecordingGuard` živi uz `@main`, koji se ne može prevesti u testu.
final class RecordingGuard {
    static let shared = RecordingGuard()
    var isRecording = false
}

// MARK: - Argumenti

struct Options {
    var outputDirectory = URL(fileURLWithPath: "/Volumes/DOMOVINA2TB/podcast_producer_output")
    var recordSeconds: Double = 75
    var previewSeconds: Double = 8
    var playsTone = true
    var title = "hardware-test"
}

var options = Options()
do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--output":
            options.outputDirectory = URL(fileURLWithPath: arguments.removeFirst())
        case "--seconds":
            options.recordSeconds = Double(arguments.removeFirst()) ?? 75
        case "--preview-seconds":
            options.previewSeconds = Double(arguments.removeFirst()) ?? 8
        case "--title":
            options.title = arguments.removeFirst()
        case "--no-tone":
            options.playsTone = false
        default:
            FileHandle.standardError.write(Data("Nepoznat argument: \(argument)\n".utf8))
            exit(2)
        }
    }
}

// MARK: - Zapisnik provjera

struct Check {
    var name: String
    var passed: Bool
    var detail: String
    /// Ne obara test — bilježi se, ali izlazni kod ostaje 0.
    var isAdvisory = false
}

var checks: [Check] = []

func record(_ name: String, _ passed: Bool, _ detail: String, advisory: Bool = false) {
    checks.append(Check(name: name, passed: passed, detail: detail, isAdvisory: advisory))
    let mark = passed ? "✅" : (advisory ? "⚠️ " : "❌")
    print("  \(mark) \(name) — \(detail)")
}

func section(_ title: String) {
    print("")
    print("── \(title) " + String(repeating: "─", count: max(0, 60 - title.count)))
}

func decibels(_ value: Float) -> String {
    value <= -119 ? "  −∞" : String(format: "%5.1f", value)
}

// MARK: - Generator zvuka

/// Pušta nepravilan niz šumnih udara kroz zadani izlazni uređaj.
///
/// Ide izravno na uređaj preko AUHAL-a umjesto na sistemski zadani izlaz, pa
/// test ne ovisi o tome što je korisnik zadnje odabrao u postavkama.
final class TonePlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isRunning = false
    private var deviceID: AudioDeviceID?
    private var restoreVolume: Float?

    /// Volume has to be set on the device we actually play through, not on the
    /// system default — those are different the moment headphones are plugged
    /// in, and raising the wrong one leaves the room silent.
    private static func volumeAddress(channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
    }

    private static func volume(of device: AudioDeviceID) -> Float? {
        // Element 0 is the master control; plenty of devices only expose the
        // individual channels, so fall back to the left one.
        for channel in [UInt32(0), UInt32(1)] {
            var address = volumeAddress(channel: channel)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    private static func setVolume(_ value: Float, on device: AudioDeviceID) {
        for channel in [UInt32(0), UInt32(1), UInt32(2)] {
            var address = volumeAddress(channel: channel)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var copy = value
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &copy)
        }
    }

    func start(deviceID: AudioDeviceID?) throws {
        self.deviceID = deviceID
        if let deviceID {
            restoreVolume = TonePlayer.volume(of: deviceID)
            TonePlayer.setVolume(0.75, on: deviceID)
        }

        if let deviceID, let audioUnit = engine.outputNode.audioUnit {
            var identifier = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &identifier,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let pattern = TonePlayer.makePattern(format: format, seconds: 20) else {
            throw NSError(domain: "TonePlayer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Ne mogu pripremiti signal za \(format)"])
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        player.scheduleBuffer(pattern, at: nil, options: .loops)
        player.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        // Leave the machine exactly as it was found.
        if let deviceID, let restoreVolume {
            TonePlayer.setVolume(restoreVolume, on: deviceID)
        }
    }

    /// Udari šuma od 45 ms na nepravilnim razmacima (0.30–0.95 s).
    ///
    /// Determinističan generator umjesto `Double.random` — kad test padne, isti
    /// signal se može reproducirati bez pogađanja.
    private static func makePattern(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount

        for channel in 0..<Int(format.channelCount) {
            memset(channels[channel], 0, Int(frameCount) * MemoryLayout<Float>.size)
        }

        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
        }

        let burstFrames = Int(sampleRate * 0.045)
        var position = Int(sampleRate * 0.15)

        while position + burstFrames < Int(frameCount) {
            for index in 0..<burstFrames {
                // Trokutasta ovojnica: oštar napad, kratak pad — daje korelatoru
                // jasan rub bez klika koji bi zvučao kao kvar zvučnika.
                let progress = Double(index) / Double(burstFrames)
                let envelope = progress < 0.1 ? progress / 0.1 : (1.0 - (progress - 0.1) / 0.9)
                let sample = Float((next() * 2 - 1) * envelope * 0.7)
                for channel in 0..<Int(format.channelCount) {
                    channels[channel][position + index] = sample
                }
            }
            position += burstFrames + Int(sampleRate * (0.30 + next() * 0.65))
        }

        return buffer
    }
}

// MARK: - Pomoćne funkcije za uređaje

func defaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    return status == noErr && deviceID != 0 ? deviceID : nil
}

/// The device the test signal must come out of: the one that fills the room.
///
/// Not the system default. Plugging in headphones silently makes them the
/// default, and the whole measurement then depends on something unrelated to the
/// studio — the burst goes into somebody's ears, the microphones hear nothing,
/// and the test reports dead microphones on perfectly healthy hardware.
///
/// Opening the speakers directly through the AUHAL also means the test never
/// touches the system's output setting, so it cannot leave the machine
/// reconfigured behind it.
func roomSpeakerDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
        return defaultOutputDeviceID()
    }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
        return defaultOutputDeviceID()
    }

    func uid(_ device: AudioDeviceID) -> String {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var valueSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &property, 0, nil, &valueSize, $0)
        }
        return status == noErr ? value as String : ""
    }

    if let speakers = ids.first(where: { uid($0) == "BuiltInSpeakerDevice" }) {
        return speakers
    }
    return defaultOutputDeviceID()
}

// MARK: - Tijek testa

@MainActor
func runHardwareTest() async -> Int32 {
    print("")
    print("🎛  Domovina Studio — test na stvarnom hardveru")
    print("   izlaz:    \(options.outputDirectory.path)")
    print("   snimanje: \(Int(options.recordSeconds)) s (+ \(Int(options.previewSeconds)) s pretpregleda)")

    // ── Priprema mape ────────────────────────────────────────────────────────
    section("Priprema")
    do {
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        record("Izlazna mapa", true, options.outputDirectory.path)
    } catch {
        record("Izlazna mapa", false, error.localizedDescription)
        return 1
    }

    if let freeBytes = HealthMonitor.availableBytes(at: options.outputDirectory) {
        let freeGB = Double(freeBytes) / 1_073_741_824.0
        record("Slobodan prostor", freeGB > 20, String(format: "%.0f GB", freeGB))
    } else {
        record("Slobodan prostor", true, "volumen ne javlja kapacitet (exFAT) — preskačem", advisory: true)
    }

    // ── Popis hardvera ───────────────────────────────────────────────────────
    section("Pronađeni uređaji")

    let model = StudioViewModel()
    model.libraryURL = options.outputDirectory
    model.sessionTitle = options.title
    model.refreshDevices()

    for device in model.availableInputs {
        print("   audio in   \(device.displayName)")
    }
    for device in model.availableVideoDevices {
        print("   video      \(device.localizedName)")
    }

    let podMics = model.availableInputs.filter {
        $0.name.localizedCaseInsensitiveContains("podmic") && !$0.name.localizedCaseInsensitiveContains("connect")
    }
    record("RØDE PodMic USB", podMics.count >= 2, "\(podMics.count) uređaja: \(podMics.map(\.uid).joined(separator: ", "))")

    let uniqueUIDs = Set(podMics.map(\.uid))
    record("Mikrofoni su odvojeni HAL uređaji", uniqueUIDs.count == podMics.count,
           "\(uniqueUIDs.count) jedinstvenih UID-jeva")

    let elgatoVideo = model.availableVideoDevices.first { $0.localizedName.localizedCaseInsensitiveContains("elgato 4k x") }
        ?? model.availableVideoDevices.first { $0.localizedName.localizedCaseInsensitiveContains("elgato") }
    record("Elgato video ulaz", elgatoVideo != nil, elgatoVideo?.localizedName ?? "nije pronađen")

    let elgatoAudio = model.availableCameraAudioDevices.first { $0.localizedName.localizedCaseInsensitiveContains("elgato 4k x") }
        ?? model.availableCameraAudioDevices.first { $0.localizedName.localizedCaseInsensitiveContains("elgato") }
    record("Elgato HDMI zvuk", elgatoAudio != nil, elgatoAudio?.localizedName ?? "nije pronađen")

    guard podMics.count >= 2, let elgatoVideo else {
        print("\n❌ Nema dovoljno hardvera za nastavak.")
        return 1
    }

    // Eksplicitna dodjela umjesto automatske — test mora biti ponovljiv i ne
    // smije ovisiti o tome što je zadnje bilo spremljeno u UserDefaults.
    model.micSlots = [
        .init(id: "mic-1", label: "Voditelj", deviceUID: podMics[0].uid),
        .init(id: "mic-2", label: "Gost", deviceUID: podMics[1].uid)
    ]
    model.selectedVideoDeviceID = elgatoVideo.uniqueID
    model.selectedCameraAudioDeviceID = elgatoAudio?.uniqueID
    model.masterCodec = .hevc

    // ── Zvučni signal ────────────────────────────────────────────────────────
    let tone = TonePlayer()
    if options.playsTone {
        do {
            try tone.start(deviceID: roomSpeakerDeviceID())
            record("Testni signal", true, "udari šuma kroz zvučnike Maca — čuju ih i mikrofoni i kamera")
        } catch {
            record("Testni signal", false, error.localizedDescription, advisory: true)
        }
    }
    defer { tone.stop() }

    // ── Pretpregled ──────────────────────────────────────────────────────────
    section("Pretpregled (\(Int(options.previewSeconds)) s)")

    await model.startPreview()
    if let error = model.lastError {
        record("Pokretanje pretpregleda", false, error)
    }

    // Mjeri i zvuk koji stiže s kamere preko HDMI-ja. `StudioViewModel` ga vodi
    // samo u korelator, a bez razine se pad lip synca ne može razlikovati od
    // kamere koja uopće ne šalje zvuk — a to je najčešći uzrok.
    let cameraMeter = LevelMeter()
    let modelHandler = model.videoController.onMonitorSamples
    model.videoController.onMonitorSamples = { samples, count, rate, hostNanos in
        modelHandler?(samples, count, rate, hostNanos)
        cameraMeter.process(samples: samples, count: count, sampleRate: rate)
    }

    // Vrhovi se prate kroz cijeli prozor: mjerač pada 60 dB/s, pa jedno očitanje
    // između dva udara pokaže tišinu na posve zdravom mikrofonu.
    var peakByMic: [String: Float] = [:]
    var cameraPeak: Float = -120
    var isRunningByMic: [String: Bool] = [:]

    let previewDeadline = Date().addingTimeInterval(options.previewSeconds)
    while Date() < previewDeadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
        for slot in model.micSlots {
            guard let status = model.micStatuses[slot.id] else { continue }
            peakByMic[slot.id] = max(peakByMic[slot.id] ?? -120, status.levels.peakDB)
            isRunningByMic[slot.id] = status.isRunning
        }
        cameraPeak = max(cameraPeak, cameraMeter.snapshot().peakDB)
    }

    let previewVideo = model.videoStatus
    record("Video sesija radi", previewVideo.isSessionRunning, "\(previewVideo.width)×\(previewVideo.height), format javlja \(Int(previewVideo.nominalFrameRate)) fps")

    for slot in model.micSlots {
        let peak = peakByMic[slot.id] ?? -120
        record("Mikrofon '\(slot.label)' čuje signal",
               (isRunningByMic[slot.id] ?? false) && peak > -55,
               "najveći vrh \(decibels(peak)) dB u \(Int(options.previewSeconds)) s")
    }

    let cameraHearsRoom = cameraPeak > -50
    record("Kamera šalje zvuk preko HDMI-ja", cameraHearsRoom,
           cameraHearsRoom
               ? "najveći vrh \(decibels(cameraPeak)) dB"
               : "najveći vrh \(decibels(cameraPeak)) dB — kamera ne šalje zvuk; lip sync se NE MOŽE izmjeriti")

    // ── Snimanje ─────────────────────────────────────────────────────────────
    section("Snimanje (\(Int(options.recordSeconds)) s)")

    await model.startRecording()
    guard model.isRecording else {
        record("Pokretanje snimanja", false, model.lastError ?? "nepoznat razlog")
        return 1
    }
    record("Pokretanje snimanja", true, model.sessionFolderURL?.lastPathComponent ?? "?")

    var sawLipSync = false
    var lastPrinted = -1

    while model.elapsedSeconds < options.recordSeconds {
        try? await Task.sleep(nanoseconds: 250_000_000)

        let second = Int(model.elapsedSeconds)
        guard second != lastPrinted, second % 5 == 0 || second == Int(options.recordSeconds) - 1 else { continue }
        lastPrinted = second

        var line = String(format: "   %3ds ", second)
        for slot in model.micSlots {
            let status = model.micStatuses[slot.id]
            let peak = status?.levels.peakDB ?? -120
            let drift = status?.driftPPM.map { String(format: "%+6.1f ppm", $0) } ?? "    — ppm"
            line += "│ \(slot.label.prefix(8)): \(decibels(peak)) dB \(drift) "
        }
        let video = model.videoStatus
        line += String(format: "│ video: %5llu fr, %llu drop, %d seg ",
                       video.videoFrameCount, video.droppedFrameCount, video.segmentsWritten)
        let sync = model.lipSync
        if sync.isValid {
            sawLipSync = true
            line += String(format: "│ sync: %+6.1f ms (%.2f)", sync.offsetMilliseconds, sync.confidence)
        } else {
            line += String(format: "│ sync: — (%.2f)", sync.confidence)
        }
        print(line)
    }

    let elapsed = model.elapsedSeconds
    let estimatedGigabytesPerHour = model.estimatedGigabytesPerHour
    await model.stopRecording()
    tone.stop()
    model.stopPreview()

    // Manifest se sprema odgođeno (500 ms coalescing) — pusti ga da slegne.
    try? await Task.sleep(nanoseconds: 1_500_000_000)

    guard let sessionFolder = model.sessionFolderURL else {
        record("Mapa sesije", false, "nije stvorena")
        return 1
    }

    // ── Provjera onoga što je ostalo na disku ────────────────────────────────
    section("Provjera snimljenog")

    let manifestURL = sessionFolder.appendingPathComponent("manifest.json")
    guard let manifestData = try? Data(contentsOf: manifestURL) else {
        record("manifest.json", false, "ne postoji na \(manifestURL.path)")
        return 1
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(SessionManifest.self, from: manifestData) else {
        record("manifest.json", false, "ne može se dekodirati")
        return 1
    }
    record("manifest.json", true, "\(manifestData.count) B, \(manifest.tracks.count) tragova, \(manifest.events.count) događaja")

    record("Trajanje sesije",
           (manifest.durationSeconds ?? 0) > options.recordSeconds - 3,
           String(format: "%.1f s (mjereno %.1f s)", manifest.durationSeconds ?? 0, elapsed))

    for slot in model.micSlots {
        guard let track = manifest.track(withID: slot.id) else {
            record("Trag '\(slot.label)'", false, "nema ga u manifestu")
            continue
        }

        let fileURL = sessionFolder.appendingPathComponent(track.relativePath)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        record("WAV '\(slot.label)'", bytes > 0, "\(track.relativePath), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")

        record("Prvi uzorak '\(slot.label)' je vremenski označen",
               track.firstSampleHostNanos != nil,
               track.firstSampleHostNanos.map { "hostNanos \($0)" } ?? "NEDOSTAJE — post ne može poravnati trag")

        let expectedFrames = (track.sampleRate ?? 48000) * elapsed
        let ratio = expectedFrames > 0 ? Double(track.sampleCount) / expectedFrames : 0
        record("Broj uzoraka '\(slot.label)'",
               ratio > 0.97 && ratio < 1.03,
               String(format: "%llu uzoraka = %.1f%% očekivanog", track.sampleCount, ratio * 100))

        if let drift = track.driftPPM {
            record("Drift '\(slot.label)'", abs(drift) < 1000, String(format: "%+.1f ppm", drift))
        } else {
            record("Drift '\(slot.label)'", false, "nije izmjeren")
        }

        record("Segmenti '\(slot.label)'", !track.segments.isEmpty, "\(track.segments.count)")
        if let offset = track.offsetSeconds(relativeTo: manifest.startedAtHostNanos ?? 0) {
            record("Pomak '\(slot.label)' od početka sesije", abs(offset) < 1.0, String(format: "%+.3f s", offset), advisory: true)
        }
    }

    if let video = manifest.track(withID: "camera-proxy") {
        let fileURL = sessionFolder.appendingPathComponent(video.relativePath)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        record("Video master", bytes > 0,
               "\(video.width ?? 0)×\(video.height ?? 0) \(video.codec ?? "?"), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")

        // Mjereno protiv sata, ne protiv `nominalFrameRate` — capture uređaj
        // javlja što njegov format može, a ne što kamera stvarno šalje.
        let measured = video.measuredFrameRate ?? (elapsed > 0 ? Double(video.sampleCount) / elapsed : 0)
        record("Izmjeren frame rate", measured > 23 && measured < 121,
               String(format: "%.2f fps (format javlja %.0f fps)", measured, video.nominalFrameRate ?? 0))

        let expectedFrames = measured * elapsed
        let ratio = expectedFrames > 0 ? Double(video.sampleCount) / expectedFrames : 0
        record("Broj frameova", ratio > 0.95,
               String(format: "%llu frameova = %.1f%% od %.2f fps × %.1f s", video.sampleCount, ratio * 100, measured, elapsed))

        record("Ispušteni frameovi", model.videoStatus.droppedFrameCount == 0,
               "\(model.videoStatus.droppedFrameCount)", advisory: true)

        let hasInit = video.segments.contains { $0.isInitialization }
        record("fMP4 inicijalizacijski segment", hasInit, hasInit ? "označen" : "NEDOSTAJE — chunkovi se ne bi mogli dekodirati")
        record("fMP4 segmenti", video.segments.count > 1, "\(video.segments.count)")
    } else {
        record("Video trag", false, "nema ga u manifestu")
    }

    // Procjena potrošnje diska nije kozmetika: na njoj se temelji odbijanje
    // snimanja u preflightu i prikaz „koliko sati još stane". Usporedi je s onim
    // što je stvarno zapisano.
    var writtenBytes = 0
    if let files = FileManager.default.enumerator(at: sessionFolder, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let url as URL in files where !url.lastPathComponent.hasPrefix("._") {
            writtenBytes += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
    }
    let actualGigabytesPerHour = elapsed > 0
        ? Double(writtenBytes) / 1_000_000_000 * 3600 / elapsed
        : 0
    let estimateRatio = actualGigabytesPerHour > 0 ? estimatedGigabytesPerHour / actualGigabytesPerHour : 0
    record("Procjena GB/h odgovara stvarnosti",
           estimateRatio > 0.7 && estimateRatio < 1.6,
           String(format: "procijenjeno %.1f GB/h, stvarno %.1f GB/h (%.0f%%)",
                  estimatedGigabytesPerHour, actualGigabytesPerHour, estimateRatio * 100))

    // Manifest je ugovor prema postprodukciji: ako tvrdi da segment ima lokalnu
    // datoteku, ona mora postojati. Oporavak sesije ide upravo po tim putanjama.
    var missingSegments: [String] = []
    var claimedSegments = 0
    for track in manifest.tracks {
        for segment in track.segments {
            guard let path = segment.relativePath else { continue }
            claimedSegments += 1
            if !FileManager.default.fileExists(atPath: sessionFolder.appendingPathComponent(path).path) {
                missingSegments.append(path)
            }
        }
    }
    record("Segmenti s lokalnom putanjom postoje na disku", missingSegments.isEmpty,
           missingSegments.isEmpty
               ? "\(claimedSegments) provjerenih"
               : "nedostaje \(missingSegments.count) od \(claimedSegments): \(missingSegments.prefix(3).joined(separator: ", "))…")

    // ── Lip sync ─────────────────────────────────────────────────────────────
    section("Lip sync")

    let confident = manifest.syncMeasurements.filter { $0.confidence > 0.3 }
    record("Mjerenja korelacije", !confident.isEmpty,
           "\(confident.count) pouzdanih od \(manifest.syncMeasurements.count)",
           advisory: !cameraHearsRoom)

    if let raw = manifest.rawSyncOffsetMilliseconds {
        record("Izmjeren pomak mikrofon→HDMI zvuk", abs(raw) < 500, String(format: "%+.1f ms", raw))
        if let resolved = manifest.resolvedSyncOffsetMilliseconds {
            let calibrated = manifest.cameraAVOffsetMilliseconds
            record("Pomak nakon kalibracije kamere", true,
                   String(format: "%+.1f ms (kalibracija: %@)", resolved,
                          calibrated.map { String(format: "%+.1f ms", $0) } ?? "nije mjerena"),
                   advisory: calibrated == nil)
        }
    } else {
        // Razlikuj "korelator ne valja" od "nema što korelirati". Bez zvuka s
        // kamere korelator nema drugu stranu jednadžbe i pad je očekivan.
        let reason: String
        if !cameraHearsRoom {
            reason = "kamera ne šalje zvuk preko HDMI-ja — korelator nema drugu stranu (vidi gore)"
        } else if sawLipSync {
            reason = "premalo pouzdanih uzoraka"
        } else {
            reason = "korelator nije uhvatio zajednički signal"
        }
        record("Izmjeren pomak mikrofon→HDMI zvuk", false, reason, advisory: !cameraHearsRoom)
    }

    if let last = manifest.syncMeasurements.last {
        let agreement = abs(last.offsetMilliseconds - last.clockOffsetMilliseconds)
        record("Sat vs. korelator", agreement < 200,
               String(format: "korelator %+.1f ms, sat %+.1f ms, razlika %.1f ms",
                      last.offsetMilliseconds, last.clockOffsetMilliseconds, agreement),
               advisory: true)
    }

    // ── Zdravlje ─────────────────────────────────────────────────────────────
    section("Zdravlje sustava na kraju")
    for item in model.health.items {
        let mark = item.severity == .ok ? "✅" : (item.severity == .warning ? "⚠️ " : "❌")
        print("  \(mark) \(item.title) — \(item.detail)")
    }
    record("Nema kritičnih upozorenja", model.health.worst != .critical, "najgore: \(model.health.worst)")

    // ── Sažetak ──────────────────────────────────────────────────────────────
    let failures = checks.filter { !$0.passed && !$0.isAdvisory }
    let advisories = checks.filter { !$0.passed && $0.isAdvisory }

    section("Sažetak")
    print("   sesija:  \(sessionFolder.path)")
    print("   prošlo:  \(checks.count - failures.count - advisories.count)/\(checks.count)")
    if !advisories.isEmpty {
        print("   pažnja:  \(advisories.count)")
        for item in advisories { print("      ⚠️  \(item.name) — \(item.detail)") }
    }
    if !failures.isEmpty {
        print("   PALO:    \(failures.count)")
        for item in failures { print("      ❌ \(item.name) — \(item.detail)") }
        print("")
        return 1
    }
    print("")
    print("✅ Cijeli lanac radi.")
    print("")
    return 0
}

Task { @MainActor in
    let status = await runHardwareTest()
    exit(status)
}

RunLoop.main.run()
