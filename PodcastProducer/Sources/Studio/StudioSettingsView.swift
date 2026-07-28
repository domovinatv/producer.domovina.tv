import SwiftUI
import AVFoundation

/// Device routing, codec choice and Cloudflare R2 credentials.
struct StudioSettingsView: View {

    // Paste helpers for the R2 tab
    @State private var dashboardURL = ""
    @State private var urlNote: String?
    @State private var apiToken = ""
    @State private var tokenNote: String?
    @State private var isDerivingKeys = false
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

    /// The one setup this studio records with, stated plainly and applied in a
    /// click.
    ///
    /// It sits above the explanation rather than inside it: getting this single
    /// choice right is the whole of the audio configuration, and everything else
    /// on this screen is detail by comparison.
    @ViewBuilder
    private var rodeConnectRecipe: some View {
        let hasMix = model.rodeConnectMixDevice != nil
        let applied = model.isRodeConnectSetupApplied

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: applied ? "checkmark.seal.fill" : "star.fill")
                    .foregroundStyle(applied ? Color.green : Color.accentColor)
                Text("Preporučena postava")
                    .font(.callout.weight(.semibold))
                Spacer()
                if !applied {
                    Button("Postavi") { model.applyRodeConnectSetup() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!hasMix || model.isRecording)
                }
            }

            Text("Jedan mikrofon, naziv **\(StudioViewModel.rodeConnectSlotLabel)**, uređaj **RØDE Connect Stream**. To je jedino što treba postaviti.")
                .font(.caption)

            if applied {
                Text("Postavljeno. Snima se obrađeni miks iz RØDE Connecta.")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if !hasMix {
                Text("„RØDE Connect Stream\" nije pronađen — provjeri je li RØDE Connect instaliran.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !model.isRodeConnectRunning {
                Text("⚠️ RØDE Connect nije pokrenut. Uređaj postoji i bez njega, ali miks je tada tišina — pokreni ga prije snimanja.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Monitor Out comes up every time, because it looks like it should be
            // the thing that feeds other apps. It is not — it only decides where
            // the operator listens, and the mix reaches us regardless.
            Text("U RØDE Connectu ne treba dirati Monitor Out — on je samo za tvoje slušalice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(applied ? Color.green.opacity(0.4) : Color.accentColor.opacity(0.4))
        )
    }

    private var devicesTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Mikrofoni", systemImage: "mic")
                    .font(.headline)
                Text("Svaki slot se snima sa svog CoreAudio uređaja, u zaseban 24-bit WAV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                rodeConnectRecipe

                DisclosureGroup("Zašto baš tako, i što je alternativa") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("**RØDE Connect (preporučeno ovdje)** — jedan slot na virtualni uređaj. Mikrofoni su na stolu preblizu jedan drugome, pa se glasovi prelijevaju; gate i miks to rješavaju uživo, na izvoru, bolje nego bilo što u postu. Dobiješ već obrađen miks umjesto sirovih tragova — za izolirane snimaj usporedno u samom RØDE Connectu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("**Direktno** — po jedan PodMic USB u svaki slot. Sirovi izolirani tragovi; svaki mikrofon ima svoj clock pa se drift mjeri i zapisuje u manifest. Namjerno bez Aggregate Devicea. Ima smisla samo ako su mikrofoni dovoljno razmaknuti.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("⚠️ Od tri virtualna uređaja samo **Stream** nosi miks. „RØDE Connect Virtual\" je tišina, a „RØDE Connect System\" je zvuk sustava — snimio bi što god Mac svira.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)

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

    /// Fills the fields below from things that can be pasted whole.
    ///
    /// Every value on this screen is a long opaque string, and two of them —
    /// the account ID and the access key — are already sitting somewhere the
    /// operator can copy from. Retyping them by hand is the single most likely
    /// way for this configuration to end up subtly wrong, and it fails late:
    /// not here, but at the first upload of a live take.
    @ViewBuilder
    private var r2PasteHelpers: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Zalijepi adresu bucketa iz Cloudflare dashboarda")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("https://dash.cloudflare.com/…/r2/default/buckets/…", text: $dashboardURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Očitaj") { applyDashboardURL() }
                        .disabled(R2DashboardURL.parse(dashboardURL) == nil)
                }
                if let note = urlNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(note.hasPrefix("✅") ? .green : .orange)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Ili zalijepi Cloudflare API token (s pravom Object Read & Write)")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    SecureField("token", text: $apiToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button(isDerivingKeys ? "Izvodim…" : "Izvedi ključeve") {
                        Task { await deriveKeys() }
                    }
                    .disabled(apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDerivingKeys)
                }
                // Not a shortcut around SigV4 — the two values genuinely are
                // derived from the token, so pasting it is exactly equivalent to
                // copying both fields, minus the transcription errors.
                Text("Access Key ID je ID tokena, a Secret je njegov SHA-256 — pa jedan token doista je dovoljan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let note = tokenNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(note.hasPrefix("✅") ? .green : .orange)
                }
            }

            if let page = R2DashboardURL.apiTokensPage(accountID: model.r2Configuration.accountID) {
                Link("Otvori stranicu za izradu ključeva ↗", destination: page)
                    .font(.caption)
            } else {
                Text("Ključevi se rade na dash.cloudflare.com → R2 → API → Manage API Tokens. Upiši Account ID gore pa se ovdje pojavi izravan link.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func applyDashboardURL() {
        guard let parsed = R2DashboardURL.parse(dashboardURL) else {
            urlNote = "Ovo ne izgleda kao adresa Cloudflare računa."
            return
        }
        model.r2Configuration.accountID = parsed.accountID
        if let bucket = parsed.bucket {
            model.r2Configuration.bucket = bucket
            urlNote = "✅ Account i bucket „\(bucket)\" očitani."
        } else {
            urlNote = "✅ Account očitan. Bucket upiši ručno — ova stranica se ne odnosi ni na jedan."
        }
        model.saveR2Configuration()
    }

    private func deriveKeys() async {
        isDerivingKeys = true
        defer { isDerivingKeys = false }
        let token = apiToken
        do {
            let id = try await R2TokenCredentials.accessKeyID(forToken: token)
            model.r2Configuration.accessKeyID = id
            model.r2SecretInput = R2TokenCredentials.secretAccessKey(forToken: token)
            model.saveR2Configuration()
            // The token itself is never stored — only what was derived from it.
            apiToken = ""
            tokenNote = "✅ Ključevi izvedeni i spremljeni. Provjeri vezu ispod."
        } catch {
            tokenNote = error.localizedDescription
        }
    }

    private var r2Tab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Spremaj na Cloudflare R2", isOn: $model.r2Configuration.isEnabled)
                .toggleStyle(.switch)

            Text("Upload nikad ne blokira snimanje. Ako veza padne, snimka se nastavlja normalno, a red za slanje se prazni kad se veza vrati.")
                .font(.caption)
                .foregroundStyle(.secondary)

            r2PasteHelpers

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
