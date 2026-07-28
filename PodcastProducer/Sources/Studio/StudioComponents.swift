import SwiftUI
import AVFoundation

// MARK: - Level meter

/// Horizontal peak/RMS meter with a peak-hold tick.
///
/// The colour breaks are at the values that matter for a podcast: green up to
/// −18 dBFS (comfortable speech), yellow to −6, red above.
struct LevelMeterView: View {
    let reading: LevelMeter.Reading
    let isActive: Bool

    private let floorDB: Float = -60

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))

                RoundedRectangle(cornerRadius: 3)
                    .fill(gradient)
                    .frame(width: geometry.size.width * fraction(reading.rmsDB))
                    .opacity(isActive ? 1 : 0.35)

                Rectangle()
                    .fill(reading.isClipping ? Color.red : Color.primary.opacity(0.7))
                    .frame(width: 2)
                    .offset(x: max(0, geometry.size.width * fraction(reading.peakHoldDB) - 1))
                    .opacity(reading.peakHoldDB > floorDB ? 1 : 0)
            }
        }
        .frame(height: 10)
    }

    private var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: fraction(-18)),
                .init(color: .yellow, location: fraction(-6)),
                .init(color: .red, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func fraction(_ db: Float) -> CGFloat {
        guard db > floorDB else { return 0 }
        return CGFloat(min(1, (db - floorDB) / (0 - floorDB)))
    }
}

// MARK: - Track strip

struct MicChannelStrip: View {
    let label: String
    let deviceName: String
    let status: AudioTrackRecorder.Status?
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(label).fontWeight(.semibold)
                Spacer()
                Text(levelText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            LevelMeterView(reading: status?.levels ?? LevelMeter.Reading(), isActive: status?.isRunning ?? false)

            HStack(spacing: 10) {
                Text(deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let status, isRecording {
                    if let drift = status.driftPPM {
                        Text(String(format: "drift %+.0f ppm", drift))
                            .font(.caption2.monospaced())
                            .foregroundStyle(abs(drift) > 100 ? .orange : .secondary)
                            .help("Odstupanje kristala mikrofona od sistemskog sata. Zapisuje se u manifest i ispravlja u postu.")
                    }
                    if status.levels.clipCount > 0 {
                        Text("\(status.levels.clipCount)× clip")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(warningBorder, lineWidth: 1.5)
        )
    }

    private var indicatorColor: Color {
        guard let status, status.isRunning else { return .secondary }
        if status.levels.isSilent { return .red }
        if status.levels.isClipping { return .orange }
        return .green
    }

    private var warningBorder: Color {
        guard isRecording, let status else { return .clear }
        if status.levels.isSilent { return .red }
        if status.levels.clipCount > 0 { return .orange.opacity(0.6) }
        return .clear
    }

    private var levelText: String {
        guard let status, status.levels.peakDB > -119 else { return "—" }
        return String(format: "%.1f dB", status.levels.peakDB)
    }
}

// MARK: - Video preview

/// Takes the controller rather than the session, because attaching the layer is
/// a session mutation and has to be serialised with everything else that touches
/// it. Assigning `previewLayer.session` straight from the main thread — which is
/// where SwiftUI builds views — crashed the app whenever it happened to land
/// while the capture queue was inside `startRunning()`.
struct CapturePreviewView: NSViewRepresentable {
    let controller: VideoCaptureController

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.videoGravity = .resizeAspect
        controller.attachPreview(to: view.previewLayer)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        controller.attachPreview(to: nsView.previewLayer)
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) nije podržan") }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}

// MARK: - Lip sync meter

/// Shows both numbers side by side on purpose. The clock offset is the one we
/// trust; the correlated offset is the independent check that the clock is
/// telling the truth.
struct SyncMeterView: View {
    let reading: LipSyncMonitor.Reading
    let hasVideo: Bool
    /// Camera's internal A/V offset from the clap calibration, if measured.
    let calibrationMilliseconds: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Lip sync", systemImage: "waveform.badge.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text(verdict)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(verdictColor.opacity(0.18))
                    .foregroundStyle(verdictColor)
                    .clipShape(Capsule())
            }

            if hasVideo {
                HStack(spacing: 24) {
                    metric(title: "Po satu", value: String(format: "%+.1f ms", reading.clockOffsetMilliseconds),
                           help: "Razlika između prvog video framea i prvog audio uzorka, mjerena na zajedničkom host clocku. Ovo ide u manifest.")
                    metric(title: "Korelacija", value: reading.isValid ? String(format: "%+.1f ms", reading.offsetMilliseconds) : "—",
                           help: "Neovisna provjera: korelacija anvelope mikrofona i HDMI zvuka iz kamere.")
                    metric(title: "Na sliku",
                           value: reading.isValid
                               ? String(format: "%+.1f ms", reading.offsetMilliseconds - (calibrationMilliseconds ?? 0))
                               : "—",
                           help: calibrationMilliseconds == nil
                               ? "Korelacija minus interni A/V pomak kamere. Kamera nije kalibrirana, pa se pretpostavlja 0 — ovo je vrijednost koju post primjenjuje."
                               : "Korelacija minus izmjereni interni A/V pomak kamere. Ovo post primjenjuje na mikrofone.")
                    metric(title: "Pouzdanost", value: String(format: "%.0f %%", reading.confidence * 100),
                           help: "Ispod 30 % korelacija nije upotrebljiva — obično znači tišina u sobi.")
                }
            } else {
                Text("Video nije aktivan — pokreni pregled da bi se mjerio lip sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metric(title: String, value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced))
        }
        .help(help)
    }

    private var verdict: String {
        guard hasVideo else { return "n/a" }
        guard reading.isValid else { return "premalo signala" }
        return reading.agreesWithClock ? "potvrđeno" : "provjeri!"
    }

    private var verdictColor: Color {
        guard hasVideo, reading.isValid else { return .secondary }
        return reading.agreesWithClock ? .green : .orange
    }
}

// MARK: - Health panel

struct HealthPanelView: View {
    let report: HealthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Stanje sustava", systemImage: "stethoscope")
                .font(.headline)

            if report.items.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Sve u redu").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(report.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: item.severity))
                            .foregroundStyle(color(for: item.severity))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.callout.weight(.medium))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func icon(for severity: HealthReport.Severity) -> String {
        switch severity {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: HealthReport.Severity) -> Color {
        switch severity {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Upload panel

struct UploadPanelView: View {
    let stats: UploadQueue.Stats
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Cloudflare R2", systemImage: "icloud.and.arrow.up")
                    .font(.headline)
                Spacer()
                if stats.failed > 0 {
                    Button("Pokušaj ponovno", action: onRetry)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            HStack(spacing: 20) {
                counter(label: "Poslano", value: "\(stats.done)", color: .green)
                counter(label: "U redu", value: "\(stats.pending + stats.uploading)", color: .secondary)
                counter(label: "Greške", value: "\(stats.failed)", color: stats.failed > 0 ? .red : .secondary)
            }

            Text(stats.backlogDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = stats.lastError, stats.failed > 0 {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func counter(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Misc

struct BigTimecodeView: View {
    let seconds: Double
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isRecording ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 12, height: 12)
                .opacity(isRecording ? 1 : 0.5)
            Text(formatted)
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
    }

    private var formatted: String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
