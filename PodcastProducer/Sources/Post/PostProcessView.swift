import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Post-production hand-off.
///
/// Two paths, because the studio has two eras of recording:
/// * **Sesija** — a take recorded by this app. The manifest already holds exact
///   host-clock offsets, so the only unknown left is where the GH5's SD-card
///   file starts relative to the captured proxy.
/// * **Riverside (naslijeđeno)** — the original `podcast_sync.sh` flow for takes
///   that were backed up to Riverside.fm instead.
struct PostProcessView: View {
    var sessionFolder: URL?

    @State private var mode: Mode = .session
    @State private var manifest: SessionManifest?
    @State private var manifestFolder: URL?
    @State private var lumixVideos: [String] = []
    @State private var copied = false
    @State private var loadError: String?

    // Legacy Riverside flow
    @AppStorage("scriptPath") private var scriptPath = ""
    @State private var riversideWav = ""
    @State private var rodeMicWav = ""
    @State private var rodeStereoWav = ""
    @State private var outputDir = ""

    enum Mode: String, CaseIterable, Identifiable {
        case session
        case riverside
        var id: String { rawValue }
        var title: String {
            switch self {
            case .session: return "Sesija iz Studija"
            case .riverside: return "Riverside (naslijeđeno)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch mode {
                    case .session: sessionFlow
                    case .riverside: riversideFlow
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: initialLoad)
    }

    // MARK: - Session flow

    private var sessionFlow: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Mapa sesije", systemImage: "folder")
                    .font(.headline)
                HStack {
                    Text(manifestFolder?.path ?? "nije odabrana")
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(manifestFolder == nil ? .secondary : .primary)
                    Spacer()
                    Button("Odaberi…") { chooseSessionFolder() }
                }
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
            }

            if let manifest {
                manifestSummary(manifest)
                Divider()
                lumixSection
                Divider()
                commandSection(command: sessionCommand)
            } else {
                Text("Odaberi mapu sesije (sadrži manifest.json) koju je snimio Studio tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func manifestSummary(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(manifest.title, systemImage: "waveform.badge.mic")
                .font(.headline)

            HStack(spacing: 24) {
                summaryItem("Trajanje", manifest.durationSeconds.map(Self.formatDuration) ?? "—")
                summaryItem("Tragova", "\(manifest.tracks.count)")
                summaryItem("Oznaka", "\(manifest.events.filter(\.isMarker).count)")
                if let remote = manifest.remote {
                    summaryItem("R2", remote.bucket)
                }
            }

            ForEach(manifest.tracks) { track in
                trackRow(track, sessionStart: manifest.startedAtHostNanos)
            }

            let markers = markerList(manifest)
            if !markers.isEmpty {
                DisclosureGroup("Oznake (\(markers.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(markers, id: \.id) { marker in
                            HStack {
                                Text(marker.timecode).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(marker.text).font(.caption)
                                Spacer()
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    private func trackRow(_ track: SessionManifest.Track, sessionStart: UInt64?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: track.kind == .cameraProxyVideo ? "video" : "mic")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.label).fontWeight(.medium)
                Text(track.relativePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let sessionStart, let offset = track.offsetSeconds(relativeTo: sessionStart) {
                    Text(String(format: "%+.3f s", offset))
                        .font(.caption.monospaced())
                        .help("Pomak početka ovog traga u odnosu na početak sesije, mjeren na zajedničkom host clocku.")
                }
                if let drift = track.driftPPM {
                    Text(String(format: "%+.0f ppm", drift))
                        .font(.caption2.monospaced())
                        .foregroundStyle(abs(drift) > 100 ? Color.orange : Color.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private struct Marker: Identifiable {
        var id: String
        var timecode: String
        var text: String
    }

    private func markerList(_ manifest: SessionManifest) -> [Marker] {
        guard let start = manifest.startedAtHostNanos else { return [] }
        var result: [Marker] = []
        for event in manifest.events where event.isMarker {
            let offset = event.hostNanos > start ? Double(event.hostNanos - start) / 1_000_000_000.0 : 0
            result.append(Marker(id: event.id, timecode: Self.formatDuration(offset), text: event.message))
        }
        return result
    }

    private var lumixSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Snimke sa SD kartice (GH5)", systemImage: "sdcard")
                .font(.headline)
            Text("Master je snimka iz kamere. Skripta je poravnava prema snimljenom proxyju i muxa s izoliranim mikrofonima — bez ponovnog renderiranja.")
                .font(.caption)
                .foregroundStyle(.secondary)

            fileList
        }
        .dropDestination(for: URL.self) { urls, _ in
            let validExtensions = ["mov", "mp4", "m4v"]
            let valid = urls.filter { validExtensions.contains($0.pathExtension.lowercased()) }
            lumixVideos.append(contentsOf: valid.map(\.path))
            return !valid.isEmpty
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if lumixVideos.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "film.stack")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("Povuci datoteke ovdje ili klikni Dodaj")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                ForEach(Array(lumixVideos.enumerated()), id: \.offset) { index, path in
                    HStack(spacing: 8) {
                        Image(systemName: "film").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.medium)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        Button {
                            lumixVideos.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.message = "Odaberi video datoteke s kamere"
                if panel.runModal() == .OK {
                    lumixVideos.append(contentsOf: panel.urls.map(\.path))
                }
            } label: {
                Label("Dodaj video datoteke", systemImage: "plus.circle")
            }
        }
    }

    private var sessionCommand: String? {
        guard let folder = manifestFolder, !lumixVideos.isEmpty else { return nil }
        let script = ScriptLocator.finalizeScriptPath() ?? "./scripts/finalize_session.sh"
        var parts = ["time", script, "\\\n  --session", "\"\(folder.path)\""]
        for video in lumixVideos {
            parts.append(contentsOf: ["\\\n  --lumix", "\"\(video)\""])
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Legacy Riverside flow

    private var riversideFlow: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Audio izvori", systemImage: "waveform")
                    .font(.headline)
                FileField(label: "Riverside Speaker 1", path: $riversideWav, types: [.wav])
                FileField(label: "Rode Mic Speaker 1", path: $rodeMicWav, types: [.wav])
                FileField(label: "Rode Stereo All Tracks", path: $rodeStereoWav, types: [.wav])
            }

            Divider()
            lumixSection
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("Izlaz", systemImage: "folder")
                    .font(.headline)
                HStack {
                    Text("Mapa").frame(width: 180, alignment: .trailing).font(.callout)
                    TextField("Odaberi izlaznu mapu…", text: $outputDir)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    Button("Odaberi") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK { outputDir = panel.url?.path ?? "" }
                    }
                }
            }

            Divider()

            HStack(spacing: 4) {
                Image(systemName: scriptPath.isEmpty ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(scriptPath.isEmpty ? Color.red : Color.green)
                    .font(.caption)
                Text(scriptPath.isEmpty ? "podcast_sync.sh nije pronađen" : scriptPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if scriptPath.isEmpty {
                    Button("Pronađi") { locateScript() }.font(.caption)
                }
            }

            commandSection(command: riversideCommand)
        }
    }

    private var riversideCommand: String? {
        guard !riversideWav.isEmpty, !rodeMicWav.isEmpty, !rodeStereoWav.isEmpty,
              !outputDir.isEmpty, !lumixVideos.isEmpty, !scriptPath.isEmpty else { return nil }

        var parts = ["time", scriptPath]
        parts.append(contentsOf: ["\\\n  --riverside-speaker-1", "\"\(riversideWav)\""])
        parts.append(contentsOf: ["\\\n  --rode-mic-speaker-1", "\"\(rodeMicWav)\""])
        parts.append(contentsOf: ["\\\n  --rode-stereo-all-tracks", "\"\(rodeStereoWav)\""])
        parts.append(contentsOf: ["\\\n  --output-dir", "\"\(outputDir)\""])
        for video in lumixVideos {
            parts.append(contentsOf: ["\\\n  --lumix", "\"\(video)\""])
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Shared

    private func commandSection(command: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Naredba", systemImage: "terminal").font(.headline)
                Spacer()
                if let command {
                    Button {
                        copyToClipboard(command)
                    } label: {
                        Label(copied ? "Kopirano!" : "Kopiraj", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                }
            }

            if let command {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Popuni sva polja da bi se generirala naredba.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Logic

    private func initialLoad() {
        autoDetectScript()
        if manifestFolder == nil, let sessionFolder {
            load(folder: sessionFolder)
        }
    }

    private func chooseSessionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SessionStore.defaultLibraryURL
        panel.message = "Odaberi mapu sesije"
        if panel.runModal() == .OK, let url = panel.url {
            load(folder: url)
        }
    }

    private func load(folder: URL) {
        let url = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            loadError = "U mapi nema manifest.json"
            manifest = nil
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            manifest = try decoder.decode(SessionManifest.self, from: data)
            manifestFolder = folder
            loadError = nil
        } catch {
            loadError = "Manifest se ne može pročitati: \(error.localizedDescription)"
            manifest = nil
        }
    }

    private func autoDetectScript() {
        if !scriptPath.isEmpty && FileManager.default.fileExists(atPath: scriptPath) { return }
        scriptPath = ScriptLocator.syncScriptPath() ?? ""
    }

    private func locateScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.shellScript]
        panel.message = "Pronađi podcast_sync.sh"
        if panel.runModal() == .OK {
            scriptPath = panel.url?.path ?? ""
        }
    }

    private func copyToClipboard(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func summaryItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Reusable

struct FileField: View {
    let label: String
    @Binding var path: String
    let types: [UTType]

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 180, alignment: .trailing)
                .font(.callout)
            TextField("Odaberi datoteku…", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            Button("Odaberi") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = types
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    path = panel.url?.path ?? ""
                }
            }
        }
    }
}
