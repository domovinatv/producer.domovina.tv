import SwiftUI
import AVFoundation

/// One-time camera A/V calibration.
///
/// Everything except one judgement is automatic: the clap transient is found in the
/// HDMI audio, and the frames around it are extracted at exact timestamps. The
/// judgement left to a human is which frame shows the hands actually meeting —
/// something eyes do instantly and a luminance detector cannot do at all, because
/// a clap has no brightness signature.
struct ClapCalibrationView: View {
    @ObservedObject var model: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .intro
    @State private var claps: [ClapCalibrator.Clap] = []
    @State private var frames: [ClapCalibrator.FrameSample] = []
    @State private var currentClap = 0
    @State private var measurements: [Double] = []
    @State private var error: String?
    @State private var countdown = 0

    enum Phase: Equatable {
        case intro
        case recording
        case analysing
        case picking
        case done
    }

    private let recordSeconds = 15

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch phase {
                    case .intro: introView
                    case .recording: recordingView
                    case .analysing: analysingView
                    case .picking: pickingView
                    case .done: doneView
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 620)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kalibracija pljeskom").font(.headline)
                Text("Jednokratno mjerenje internog A/V pomaka kamere")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let existing = CameraCalibrationStore.offsetMilliseconds {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%+.1f ms", existing))
                        .font(.callout.monospaced().weight(.medium))
                    if let at = CameraCalibrationStore.measuredAt {
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if CameraCalibrationStore.offsetMilliseconds != nil && phase == .intro {
                Button("Izbriši kalibraciju") {
                    CameraCalibrationStore.clear()
                    model.refreshCalibration()
                    dismiss()
                }
                .foregroundStyle(.red)
            }
            Spacer()
            if phase == .intro {
                Button {
                    Task { await start() }
                } label: {
                    Label("Snimi kalibraciju", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
            Button(phase == .done ? "Gotovo" : "Odustani") { dismiss() }
                .keyboardShortcut(phase == .done ? .defaultAction : .cancelAction)
        }
        .padding()
    }

    // MARK: - Phases

    private var introView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Zašto ovo treba točno jednom")
                .font(.headline)
            Text("""
                 Korelator mjeri pomak između mikrofona i HDMI **zvuka** iz kamere. \
                 To je jednako pomaku do **slike** samo ako kamera preko HDMI-ja \
                 emitira zvuk poravnan sa slikom. Obično je tako. Ako nije, svaka \
                 snimka je pomaknuta za istu konstantu — a ništa na ekranu to ne bi \
                 pokazalo.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Pljesak to rješava jer zvuk i svjetlo odlaze iz ruku u istom trenutku i s istog mjesta.")
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                Label("Pljesni **blizu kamere** — 30 cm ili manje", systemImage: "1.circle.fill")
                Text("Zvuku treba ~2,9 ms na metar, i ta kašnjenja ulaze u mjerenje. Na 30 cm je pod milisekundu.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                Label("Ruke moraju biti **u kadru**", systemImage: "2.circle.fill")
                Label("Pljesni 3 puta, s pauzom od barem sekunde", systemImage: "3.circle.fill")
            }
            .font(.callout)

            if !model.isPreviewing {
                Label("Uključi Pregled prije snimanja — treba i slika i HDMI zvuk.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private var recordingView: some View {
        VStack(spacing: 20) {
            Spacer()
            Circle()
                .fill(.red)
                .frame(width: 100, height: 100)
                .overlay(Text("\(countdown)").font(.system(size: 40, weight: .bold)).foregroundStyle(.white))
            Text("Pljesni sada — 3 puta, blizu kamere")
                .font(.title3.weight(.medium))
            Text("Snimam \(recordSeconds) s")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var analysingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
            Text("Tražim pljeskove i izvlačim frameove…").font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var pickingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Pljesak \(currentClap + 1) od \(claps.count)").font(.headline)
                Spacer()
                if currentClap < claps.count {
                    Text(String(format: "zvuk na %.3f s", claps[currentClap].audioSeconds))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }

            Text("Klikni frame na kojem se ruke **spoje**. Plava crta je trenutak zvuka.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(frames) { frame in
                        let delta = currentClap < claps.count
                            ? (claps[currentClap].audioSeconds - frame.seconds) * 1000 : 0
                        Button {
                            pick(frame)
                        } label: {
                            VStack(spacing: 4) {
                                Image(decorative: frame.image, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(abs(delta) < 0.6 ? Color.blue : Color.clear,
                                                    lineWidth: 2)
                                    )
                                Text(String(format: "%+.0f ms", delta))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(abs(delta) < 0.6 ? .blue : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            if !measurements.isEmpty {
                Text("Izmjereno do sada: " + measurements.map { String(format: "%+.1f ms", $0) }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button("Preskoči ovaj pljesak") { advance() }
                .buttonStyle(.link)
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 16) {
            let result = ClapCalibrator.offsetMilliseconds(from: measurements) ?? 0
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text(String(format: "Interni A/V pomak kamere: %+.1f ms", result))
                        .font(.title3.weight(.semibold))
                    Text("medijan iz \(measurements.count) mjerenja")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(interpretation(result))
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Konstanta se od sada odbija od izmjerenog pomaka korelacije, i zapisuje se u manifest svake sesije.")
                .font(.caption).foregroundStyle(.secondary)

            Button("Spremi kalibraciju") {
                CameraCalibrationStore.save(result)
                model.refreshCalibration()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func interpretation(_ value: Double) -> String {
        if abs(value) < 12 {
            return "Praktički nula — HDMI zvuk je poravnan sa slikom, kako se i pretpostavljalo. Korelator je i bez ovoga bio dovoljan."
        }
        if abs(value) < 60 {
            return "Kamera ima mjerljiv interni pomak. Bez ove konstante svaka bi snimka bila pomaknuta za toliko."
        }
        return "Velik pomak. Provjeri da si pljesnuo blizu kamere i da su odabrani frameovi točni — ponovi mjerenje ako nisi siguran."
    }

    // MARK: - Flow

    private func pick(_ frame: ClapCalibrator.FrameSample) {
        guard currentClap < claps.count else { return }
        measurements.append((claps[currentClap].audioSeconds - frame.seconds) * 1000)
        advance()
    }

    private func advance() {
        currentClap += 1
        if currentClap >= claps.count {
            phase = measurements.isEmpty ? .intro : .done
            if measurements.isEmpty { error = "Nije odabran ni jedan frame." }
            return
        }
        Task { await loadFrames() }
    }

    private func loadFrames() async {
        guard let url = model.calibrationClipURL, currentClap < claps.count else { return }
        do {
            frames = try await ClapCalibrator.frames(
                around: claps[currentClap].audioSeconds, in: url, count: 13
            )
        } catch {
            self.error = error.localizedDescription
            phase = .intro
        }
    }

    private func start() async {
        error = nil
        measurements = []
        currentClap = 0
        phase = .recording
        countdown = recordSeconds

        do {
            try await model.recordCalibrationClip(seconds: recordSeconds) { remaining in
                countdown = remaining
            }
            phase = .analysing
            guard let url = model.calibrationClipURL else {
                throw ClapCalibrator.CalibrationError.noVideoTrack
            }
            claps = try await ClapCalibrator.detectClaps(in: url, maxCount: 4)
            guard !claps.isEmpty else { throw ClapCalibrator.CalibrationError.noClapsFound }
            await loadFrames()
            phase = .picking
        } catch {
            self.error = error.localizedDescription
            phase = .intro
        }
    }

    private var canStart: Bool { model.isPreviewing && phase == .intro }
}
