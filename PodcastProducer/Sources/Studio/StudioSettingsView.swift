import SwiftUI
import AVFoundation

/// Device routing, codec choice and Cloudflare R2 credentials.
struct StudioSettingsView: View {
    @ObservedObject var model: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    @State private var showCalibration = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Uređaji").tag(0)
                Text("Snimanje").tag(1)
                Text("Cloudflare R2").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            ScrollView {
                Group {
                    switch selectedTab {
                    case 0: devicesTab
                    case 1: recordingTab
                    default: r2Tab
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button("Osvježi uređaje") { model.refreshDevices() }
                Spacer()
                Button("Gotovo") {
                    model.commitSelections()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 620)
        .sheet(isPresented: $showCalibration) {
            ClapCalibrationView(model: model)
        }
    }

    // MARK: - Devices

    private var devicesTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Mikrofoni", systemImage: "mic")
                    .font(.headline)
                Text("Svaki slot se snima sa svog CoreAudio uređaja, u zaseban 24-bit WAV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Dvije moguće postave:")
                        .font(.caption.weight(.semibold))
                    Text("**Direktno** — po jedan PodMic USB u svaki slot. Sirovi izolirani tragovi; svaki mikrofon ima svoj clock pa se drift mjeri i zapisuje u manifest. Namjerno bez Aggregate Devicea.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("**RØDE Connect** — jedan slot na virtualni uređaj. Prelijevanje glasova, gate i miks radi RØDE, sync se svodi na jednu korelaciju prema kameri. Ali dobiješ već obrađen miks, ne sirove tragove — za izolirane snimaj i u RØDE Connectu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("⚠️ „RØDE Connect System\" je zvuk sustava, ne mikrofoni. Uključi Pregled i govori — mjerač pokazuje koji je ulaz pravi.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                ForEach($model.micSlots) { $slot in
                    HStack(spacing: 8) {
                        TextField("Naziv", text: $slot.label)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)

                        Picker("", selection: $slot.deviceUID) {
                            Text("— nije dodijeljen —").tag(String?.none)
                            ForEach(model.availableInputs) { device in
                                Text(device.displayName).tag(String?.some(device.uid))
                            }
                        }
                        .labelsHidden()

                        Button {
                            model.removeMicSlot(id: slot.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isRecording)
                    }
                }

                Button {
                    model.addMicSlot()
                } label: {
                    Label("Dodaj mikrofon", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
                .disabled(model.isRecording)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Kamera (Elgato)", systemImage: "video")
                    .font(.headline)

                Picker("Video ulaz", selection: $model.selectedVideoDeviceID) {
                    Text("— nije odabran —").tag(String?.none)
                    ForEach(model.availableVideoDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(String?.some(device.uniqueID))
                    }
                }

                Picker("HDMI zvuk", selection: $model.selectedCameraAudioDeviceID) {
                    Text("— nije odabran —").tag(String?.none)
                    ForEach(model.availableCameraAudioDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(String?.some(device.uniqueID))
                    }
                }

                Text("HDMI zvuk iz GH5 se ne koristi za finalni miks — služi kao referenca za lip sync i za poravnavanje snimke sa SD kartice u postu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Kalibracija pljeskom", systemImage: "hands.clap")
                    .font(.headline)
                Text("Korelator mjeri pomak do HDMI **zvuka**. To je pomak do **slike** samo ako kamera emitira zvuk poravnan sa slikom. Pljesak to provjeri — jednom, ne po epizodi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if let offset = model.cameraAVOffsetMilliseconds {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text(String(format: "%+.1f ms", offset))
                                .font(.callout.monospaced().weight(.medium))
                            if let at = CameraCalibrationStore.measuredAt {
                                Text("· \(at.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                            Text("nije mjereno — pretpostavlja se 0 ms")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(model.cameraAVOffsetMilliseconds == nil ? "Kalibriraj…" : "Ponovi…") {
                        showCalibration = true
                    }
                    .disabled(!model.isPreviewing)
                }
                if !model.isPreviewing {
                    Text("Uključi Pregled da bi kalibracija bila moguća.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .disabled(model.isRecording)
    }

    // MARK: - Recording

    private var recordingTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Kodek lokalnog proxyja", systemImage: "film")
                    .font(.headline)

                Picker("", selection: $model.masterCodec) {
                    ForEach(VideoCaptureController.MasterCodec.allCases) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Text(String(format: "Procjena: %.0f GB po satu (uključujući audio).", model.estimatedGigabytesPerHour))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Master ostaje snimka na SD kartici GH5. Ovaj proxy je savršeno sinkronizirana referenca, live pregled i sigurnosna kopija.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Mapa sesija", systemImage: "folder")
                    .font(.headline)
                HStack {
                    Text(model.libraryURL.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Promijeni") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.message = "Odaberi mapu za snimke"
                        if panel.runModal() == .OK, let url = panel.url {
                            model.libraryURL = url
                            model.commitSelections()
                        }
                    }
                }
                if let free = HealthMonitor.availableBytes(at: model.libraryURL) {
                    Text("Slobodno: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.isRecording)
    }

    // MARK: - R2

    private var r2Tab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Spremaj na Cloudflare R2", isOn: $model.r2Configuration.isEnabled)
                .toggleStyle(.switch)

            Text("Upload nikad ne blokira snimanje. Ako veza padne, snimka se nastavlja normalno, a red za slanje se prazni kad se veza vrati.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Account ID").gridColumnAlignment(.trailing)
                    TextField("npr. 8f3c…", text: $model.r2Configuration.accountID)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Bucket").gridColumnAlignment(.trailing)
                    TextField("npr. domovina-podcast", text: $model.r2Configuration.bucket)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Access Key ID").gridColumnAlignment(.trailing)
                    TextField("", text: $model.r2Configuration.accessKeyID)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Secret Key").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        SecureField(model.hasStoredR2Secret ? "•••••••• (spremljen u Keychain)" : "", text: $model.r2SecretInput)
                            .textFieldStyle(.roundedBorder)
                        Text("Sprema se u macOS Keychain, nikad na disk ni u manifest.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Prefiks").gridColumnAlignment(.trailing)
                    TextField("sessions", text: $model.r2Configuration.prefix)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle("Šalji segmente tijekom snimanja", isOn: $model.r2Configuration.uploadDuringRecording)
            Toggle("Pošalji master datoteke nakon zaustavljanja", isOn: $model.r2Configuration.uploadMastersAfterStop)

            HStack {
                Button("Spremi") { model.saveR2Configuration() }
                    .buttonStyle(.borderedProminent)
                Button("Provjeri vezu") {
                    model.saveR2Configuration()
                    Task { await model.verifyR2Access() }
                }
                Spacer()
            }

            if let status = model.r2Status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("✅") ? .green : .primary)
                    .textSelection(.enabled)
            }
        }
    }
}
