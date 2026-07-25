import SwiftUI
import AVFoundation

/// The live take screen. Everything that can ruin a recording is visible
/// without scrolling: levels, sync, disk, upload backlog.
struct StudioView: View {
    @ObservedObject var model: StudioViewModel
    @State private var showSettings = false
    @State private var markerText = ""

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 380, idealWidth: 420)
            rightColumn
                .frame(minWidth: 460)
        }
        .sheet(isPresented: $showSettings) {
            StudioSettingsView(model: model)
        }
        .alert("Greška", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("U redu") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Left column

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                transportSection
                Divider()
                microphoneSection
                Divider()
                SyncMeterView(reading: model.lipSync, hasVideo: model.isPreviewing,
                              calibrationMilliseconds: model.cameraAVOffsetMilliseconds)
                HealthPanelView(report: model.health)
                UploadPanelView(stats: model.uploadStats) {
                    Task { await model.retryFailedUploads() }
                }
            }
            .padding(16)
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BigTimecodeView(seconds: model.elapsedSeconds, isRecording: model.isRecording)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Postavke: uređaji, kodek, Cloudflare R2")
            }

            TextField("Naziv epizode", text: $model.sessionTitle)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isRecording)

            HStack(spacing: 10) {
                if model.isRecording {
                    Button {
                        Task { await model.stopRecording() }
                    } label: {
                        Label("Zaustavi", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(model.isStopping)
                } else {
                    Button {
                        Task { await model.startRecording() }
                    } label: {
                        Label("Snimaj", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(model.assignedMicrophones.isEmpty || !model.health.isSafeToRecord)
                }

                Button {
                    Task {
                        model.isPreviewing ? model.stopPreview() : await model.startPreview()
                    }
                } label: {
                    Label(model.isPreviewing ? "Pregled uklj." : "Pregled", systemImage: "video")
                }
                .controlSize(.large)
                .disabled(model.isRecording)
            }

            if model.isRecording {
                HStack(spacing: 8) {
                    TextField("Oznaka (npr. 'dobar odgovor')", text: $markerText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addMarker)
                    Button("Označi", action: addMarker)
                        .disabled(markerText.isEmpty)
                }
                .help("Oznake se spremaju u manifest s točnim vremenom — koristi ih u montaži.")
            }

            if let folder = model.sessionFolderURL {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.caption)
                    Text(folder.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Otvori") { NSWorkspace.shared.open(folder) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private func addMarker() {
        guard !markerText.isEmpty else { return }
        model.addMarker(markerText)
        markerText = ""
    }

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mikrofoni", systemImage: "mic")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Osvježi popis uređaja")
            }

            if model.assignedMicrophones.isEmpty {
                Text("Nijedan mikrofon nije dodijeljen. Otvori postavke i odaberi ulaze.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if model.isUsingAggregatedVirtualInput {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text("Snima se RØDE Connect miks — jedan trag, obrada je već ukuhana. Za izolirane sirove tragove snimaj u RØDE Connectu paralelno ili dodijeli PodMic uređaje direktno.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !model.isRecording && !model.isPreviewing && !model.assignedMicrophones.isEmpty {
                Text("Uključi Pregled da vidiš razine — tako provjeriš da je odabran pravi ulaz.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ForEach(model.micSlots) { slot in
                let device = model.availableInputs.first { $0.uid == slot.deviceUID }
                MicChannelStrip(
                    label: slot.label,
                    deviceName: device?.name ?? "nije dodijeljen",
                    status: model.micStatuses[slot.id],
                    isRecording: model.isRecording
                )
            }
        }
    }

    // MARK: - Right column

    private var rightColumn: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if model.isPreviewing {
                    CapturePreviewView(session: model.videoController.session)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("Pregled je isključen")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            videoStatusBar
            Divider()
            eventLog
                .frame(height: 160)
        }
    }

    private var videoStatusBar: some View {
        HStack(spacing: 16) {
            statusItem(
                icon: "camera",
                text: model.videoStatus.width > 0
                    ? "\(model.videoStatus.width)×\(model.videoStatus.height) @ \(Int(model.videoStatus.nominalFrameRate))"
                    : "—"
            )
            statusItem(icon: "film", text: "\(model.videoStatus.videoFrameCount) frameova")
            if model.videoStatus.droppedFrameCount > 0 {
                statusItem(icon: "exclamationmark.triangle", text: "\(model.videoStatus.droppedFrameCount) ispušteno")
                    .foregroundStyle(.orange)
            }
            statusItem(icon: "shippingbox", text: "\(model.videoStatus.segmentsWritten) segmenata")
            Spacer()
            Text(model.masterCodec.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).monospacedDigit()
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Dnevnik sesije", systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.recentEvents) { event in
                        HStack(alignment: .top, spacing: 6) {
                            Text(Self.timeFormatter.string(from: event.at))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            if event.isMarker {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.blue)
                            }
                            Text(event.message)
                                .font(.system(size: 11))
                                .foregroundStyle(color(for: event.level))
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(for level: SessionManifest.Event.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
