import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Post-production, run from inside the app.
///
/// Two live paths:
///
/// * **Sesija** — recorded by this app; the manifest holds exact host-clock
///   offsets, so the only unknown left is where the GH5's SD-card file starts
///   relative to the captured proxy. Runs `finalize_session.sh`.
/// * **Backup** — the session did NOT go through the app: only the camera's
///   SD master and RØDE Connect's mix exist. Everything is measured by
///   correlation. Runs `finalize_backup.sh`.
///
/// Both end in a `*_youtube.mp4` and can then feed **Priprema za YouTube**
/// (Modal transcription + AI metadata). The scripts remain the single source
/// of truth for every ffmpeg invocation — the app launches and shows them.
///
/// The older **Riverside** flow — a builder for the original `podcast_sync.sh`
/// command, for takes that were backed up to Riverside.fm — is still compiled
/// and wired below, but no longer reachable: nothing new is recorded that way.
/// See `Mode.selectable` for how to put it back.
struct PostProcessView: View {
    var sessionFolder: URL?
    /// The session library from Studio settings. Post opens on its contents,
    /// newest first, so a take is picked from a list instead of hunted for in
    /// a file panel.
    var libraryURL: URL

    @State private var mode: Mode = .session
    @State private var manifest: SessionManifest?
    @State private var manifestFolder: URL?
    @State private var lumixVideos: [String] = []
    @State private var copied = false
    @State private var loadError: String?

    // Session library listing
    @State private var sessions: [SessionLibrary.Entry] = []
    @State private var libraryProblem: String?
    @State private var isScanningLibrary = false

    // In-app script execution
    @StateObject private var exportRunner = ScriptRunner()
    @StateObject private var prepRunner = ScriptRunner()
    @State private var makeYouTube = true

    // Backup flow (no manifest — camera SD master + RØDE Connect mix)
    @State private var backupAudioWav = ""
    @State private var backupOutputDir = ""
    @State private var backupLoudness = true
    @State private var backupStart = ""
    @State private var backupEnd = ""

    // Lip sync preview
    @State private var preview: SyncPreviewPlayer.Result?
    @State private var previewError: String?
    @State private var player: AVPlayer?
    @State private var nudgeMilliseconds: Double = 0
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?

    // Legacy Riverside flow
    @AppStorage("scriptPath") private var scriptPath = ""
    @State private var riversideWav = ""
    @State private var rodeMicWav = ""
    @State private var rodeStereoWav = ""
    @State private var outputDir = ""

    enum Mode: String, CaseIterable, Identifiable {
        case session
        case backup
        case riverside
        var id: String { rawValue }
        var title: String {
            switch self {
            case .session: return "Sesija iz Studija"
            case .backup: return "Backup (RØDE + SD)"
            case .riverside: return "Riverside (naslijeđeno)"
            }
        }

        /// What the picker offers. Riverside is retired from the UI but kept in
        /// the codebase — the archive it services is finite and already
        /// recorded, and `podcast_sync.sh` still runs from the command line.
        /// Adding `.riverside` here brings the tab back.
        static let selectable: [Mode] = [.session, .backup]
    }

    var body: some View {
        VStack(spacing: 0) {
            // With a single mode there is nothing to choose, so the picker
            // stays out of the way rather than showing one lonely segment.
            if Mode.selectable.count > 1 {
                Picker("", selection: $mode) {
                    ForEach(Mode.selectable) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(16)

                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch mode {
                    case .session: sessionFlow
                    case .backup: backupFlow
                    case .riverside: riversideFlow
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            initialLoad()
            Task { await reloadLibrary() }
        }
        .onChange(of: libraryURL) {
            Task { await reloadLibrary() }
        }
    }

    // MARK: - Session flow

    private var sessionFlow: some View {
        VStack(alignment: .leading, spacing: 22) {
            libraryList

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
                syncPreviewSection(manifest)
                Divider()
                lumixSection
                Divider()
                sessionExportSection
                Divider()
                YouTubePrepSection(defaultInput: exportRunner.producedFile, runner: prepRunner)
            } else {
                Text("Odaberi mapu sesije (sadrži manifest.json) koju je snimio Studio tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Session library

    /// Everything in the configured library, newest first.
    ///
    /// The file panel stays available below for takes that live somewhere else,
    /// but choosing the episode recorded an hour ago should not require
    /// navigating to it.
    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Snimke", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                if isScanningLibrary {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("\(sessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    Task { await reloadLibrary() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Osvježi popis snimki")
            }

            Text(libraryURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            if let libraryProblem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .foregroundStyle(.orange)
                    Text(libraryProblem)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } else if sessions.isEmpty {
                Text(isScanningLibrary ? "Čitam mapu sesija…" : "U mapi sesija nema nijedne snimke.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sessions) { entry in
                            sessionRow(entry)
                        }
                    }
                }
                // Tall enough to show a handful without pushing the rest of
                // post-production off the screen.
                .frame(maxHeight: 260)
            }
        }
    }

    private func sessionRow(_ entry: SessionLibrary.Entry) -> some View {
        let isCurrent = manifestFolder?.standardizedFileURL == entry.url.standardizedFileURL
        return Button {
            load(folder: entry.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isReadable
                      ? (entry.hasVideo ? "video.fill" : "waveform")
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(entry.isReadable ? (isCurrent ? Color.accentColor : Color.secondary) : Color.orange)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    Text(entry.url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                    Text(entry.isReadable ? rowDetail(entry) : "manifest se ne može pročitati")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isCurrent ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowDetail(_ entry: SessionLibrary.Entry) -> String {
        let tracks = "\(entry.trackCount) \(entry.trackCount == 1 ? "trag" : "tragova")"
        guard let duration = entry.durationSeconds else { return "\(tracks) · bez trajanja" }
        return "\(Self.formatDuration(duration)) · \(tracks)"
    }

    private func reloadLibrary() async {
        let library = libraryURL
        isScanningLibrary = true
        // Off the main thread: the library normally sits on an external drive,
        // and a spun-down disk would otherwise freeze the window.
        let scan = await Task.detached(priority: .userInitiated) {
            SessionLibrary.scan(library)
        }.value
        // A slow scan of a folder the user has since changed away from must not
        // overwrite the newer one.
        guard library == libraryURL else { return }
        sessions = scan.entries
        libraryProblem = scan.problem
        isScanningLibrary = false
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

            syncRow(manifest)

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

    // MARK: - Lip sync preview

    /// Plays the take with sync already applied, before anything is rendered.
    ///
    /// The point is the order of operations: finalize is a long job on a large
    /// file, and running it only to discover the sync is wrong wastes all of it.
    /// Here the picture and the isolated microphones are placed on one timeline
    /// and played live, so the answer arrives in seconds. The nudge slider is
    /// deliberately included — if what the correlator measured looks off, the
    /// right value can be found by ear and handed straight to finalize.
    @ViewBuilder
    private func syncPreviewSection(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Provjera lip synca", systemImage: "play.rectangle")
                .font(.headline)

            if let preview {
                if preview.hasVideo {
                    SyncPlayerView(player: player)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack {
                        Image(systemName: "waveform")
                        Text("Sesija nema sliku — reproducira se samo zvuk.")
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // AVPlayerLayer draws the picture but brings no controls, so the
                // transport is ours.
                HStack(spacing: 12) {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                    }
                    Slider(value: Binding(
                        get: { currentTime },
                        set: { seek(to: $0) }
                    ), in: 0...max(duration, 0.1))
                    Text(String(format: "%d:%02d / %d:%02d",
                                Int(currentTime) / 60, Int(currentTime) % 60,
                                Int(duration) / 60, Int(duration) % 60))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Text("Pomak")
                    Slider(value: $nudgeMilliseconds, in: -400...400, step: 1)
                    Text(String(format: "%+.0f ms", nudgeMilliseconds))
                        .font(.callout.monospaced().weight(.medium))
                        .frame(width: 78, alignment: .trailing)
                    Button("Primijeni") { Task { await rebuildPreview(manifest) } }
                        .disabled(abs(nudgeMilliseconds - preview.appliedOffsetMilliseconds) < 0.5)
                }

                if abs(nudgeMilliseconds - (manifest.resolvedSyncOffsetMilliseconds ?? 0)) > 0.5 {
                    Text(String(format: "Izmjereno je %+.0f ms. Ako ovo zvuči bolje, dodaj skripti --sync-offset-ms %.0f",
                                manifest.resolvedSyncOffsetMilliseconds ?? 0, nudgeMilliseconds))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                ForEach(preview.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            } else if let previewError {
                Text(previewError).font(.callout).foregroundStyle(.red)
            } else {
                HStack {
                    Text("Sastavi sliku i izolirane mikrofone na jednu vremensku os i poslušaj prije renderiranja.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pripremi") { Task { await rebuildPreview(manifest) } }
                }
            }
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    private func seek(to seconds: Double) {
        currentTime = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Drives the scrubber. Removed with the old player, or it would keep firing
    /// against a composition that no longer exists after a rebuild.
    private func observeTime(of newPlayer: AVPlayer) {
        if let timeObserver, let old = player { old.removeTimeObserver(timeObserver) }
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { time in
            currentTime = CMTimeGetSeconds(time)
        }
    }

    private func rebuildPreview(_ manifest: SessionManifest) async {
        guard let folder = manifestFolder else { return }
        player?.pause()
        isPlaying = false
        previewError = nil
        do {
            let built = try await SyncPreviewPlayer.build(
                manifest: manifest,
                sessionURL: folder,
                offsetOverrideMilliseconds: preview == nil ? nil : nudgeMilliseconds
            )
            let item = AVPlayerItem(asset: built.composition)
            let newPlayer = AVPlayer(playerItem: item)
            observeTime(of: newPlayer)
            duration = CMTimeGetSeconds(try await built.composition.load(.duration))
            currentTime = 0
            player = newPlayer
            preview = built
            nudgeMilliseconds = built.appliedOffsetMilliseconds
        } catch {
            previewError = error.localizedDescription
            preview = nil
            player = nil
        }
    }

    /// The measured microphone→picture offset. Shown prominently because if it is
    /// missing, the finalize script can only align by host clock and the audio
    /// ends up ahead of the picture.
    @ViewBuilder
    private func syncRow(_ manifest: SessionManifest) -> some View {
        let hasVideo = manifest.tracks.contains { $0.kind == .cameraProxyVideo }
        if hasVideo {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: manifest.resolvedSyncOffsetMilliseconds != nil
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(manifest.resolvedSyncOffsetMilliseconds != nil ? Color.green : Color.orange)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pomak mikrofon → slika").fontWeight(.medium)
                    if manifest.resolvedSyncOffsetMilliseconds != nil {
                        Text("medijan iz \(manifest.syncMeasurements.count) mjerenja korelacije HDMI zvuka")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("nema pouzdanih mjerenja — poravnava se samo po satu, latencija lanca ostaje")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if let offset = manifest.resolvedSyncOffsetMilliseconds {
                    Text(String(format: "%+.1f ms", offset))
                        .font(.callout.monospaced().weight(.medium))
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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

    // MARK: - Session export (in-app)

    /// Arguments for `finalize_session.sh`, shared by the in-app runner and
    /// the copyable command line so the two can never diverge.
    private var sessionArguments: [String]? {
        guard let folder = manifestFolder, !lumixVideos.isEmpty else { return nil }
        var arguments = ["--session", folder.path]
        for video in lumixVideos { arguments += ["--lumix", video] }
        if let override = syncOverrideMilliseconds {
            arguments += ["--sync-offset-ms", String(format: "%.0f", override)]
        }
        if makeYouTube { arguments.append("--youtube") }
        return arguments
    }

    /// Non-nil when the nudge slider was moved away from the measured offset:
    /// the human overruled the correlator by ear, and that decision has to
    /// reach the script, not just the preview.
    private var syncOverrideMilliseconds: Double? {
        guard preview != nil else { return nil }
        let measured = manifest?.resolvedSyncOffsetMilliseconds ?? 0
        return abs(nudgeMilliseconds - measured) > 0.5 ? nudgeMilliseconds : nil
    }

    private var sessionCommand: String? {
        guard let arguments = sessionArguments else { return nil }
        let script = ScriptLocator.finalizeScriptPath() ?? "./scripts/finalize_session.sh"
        return displayCommand(script: script, arguments: arguments)
    }

    private var sessionExportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Izvoz", systemImage: "square.and.arrow.up")
                .font(.headline)
            Text("Drift, poravnanje, miks i mux sa SD masterom — video se ne renderira. Pokreće scripts/finalize_session.sh.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Napravi i YouTube datoteku (−14 LUFS, AAC 384k, faststart)", isOn: $makeYouTube)
                .font(.callout)

            if let override = syncOverrideMilliseconds {
                Text(String(format: "Koristi se ručni pomak %+.0f ms iz klizača (izmjereno: %+.0f ms).",
                            override, manifest?.resolvedSyncOffsetMilliseconds ?? 0))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if ScriptLocator.finalizeScriptPath() == nil {
                Text("scripts/finalize_session.sh nije pronađen — provjeri instalaciju.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button {
                    runSessionExport()
                } label: {
                    Label("Pokreni finalizaciju", systemImage: "play.circle.fill")
                }
                .disabled(sessionArguments == nil || ScriptLocator.finalizeScriptPath() == nil
                          || exportRunner.isRunning)

                if let command = sessionCommand {
                    CopyButton(label: "Kopiraj naredbu za Terminal", value: command)
                }
            }

            ScriptRunnerStatusView(runner: exportRunner)
        }
    }

    private func runSessionExport() {
        guard let arguments = sessionArguments,
              let script = ScriptLocator.finalizeScriptPath() else { return }
        exportRunner.run(script: script, arguments: arguments)
    }

    /// A readable, pasteable rendition of what the runner executes.
    private func displayCommand(script: String, arguments: [String]) -> String {
        var parts = ["time", "\"\(script)\""]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), index + 1 < arguments.count,
               !arguments[index + 1].hasPrefix("--") {
                parts.append("\\\n  \(argument) \"\(arguments[index + 1])\"")
                index += 2
            } else {
                parts.append("\\\n  \(argument)")
                index += 1
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Backup flow (no manifest)

    private var backupFlow: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Backup snimka — bez manifesta", systemImage: "externaldrive.badge.timemachine")
                    .font(.headline)
                Text("Za sesije koje nisu prošle kroz aplikaciju: SD master s kamere + StereoMix.wav iz RØDE Connecta. Svi pomaci se mjere korelacijom na tri točke (scripts/finalize_backup.sh).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            lumixSection
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("Zvuk i izlaz", systemImage: "waveform")
                    .font(.headline)
                FileField(label: "Mix (StereoMix.wav)", path: $backupAudioWav, types: [.wav])
                HStack {
                    Text("Izlazna mapa").frame(width: 180, alignment: .trailing).font(.callout)
                    TextField("Odaberi izlaznu mapu…", text: $backupOutputDir)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    Button("Odaberi") { chooseBackupOutputDir() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("Izvoz", systemImage: "square.and.arrow.up")
                    .font(.headline)
                Toggle("Normaliziraj glasnoću na −14 LUFS (YouTube)", isOn: $backupLoudness)
                    .font(.callout)
                HStack {
                    Text("Rez").frame(width: 180, alignment: .trailing).font(.callout)
                    TextField("početak (s ili HH:MM:SS)", text: $backupStart)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .frame(width: 180)
                    TextField("kraj (prazno = do kraja)", text: $backupEnd)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .frame(width: 180)
                    Spacer()
                }
                Text("Prvo smoke test: 45 s iz sredine, s automatskom provjerom sinkrona u isječku — pa tek onda puni izvoz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if ScriptLocator.backupScriptPath() == nil {
                    Text("scripts/finalize_backup.sh nije pronađen — provjeri instalaciju.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button {
                        runBackup(smoke: true)
                    } label: {
                        Label("Smoke test (45 s)", systemImage: "testtube.2")
                    }
                    .disabled(backupArguments(smoke: true) == nil
                              || ScriptLocator.backupScriptPath() == nil
                              || exportRunner.isRunning)

                    Button {
                        runBackup(smoke: false)
                    } label: {
                        Label("Puni izvoz za YouTube", systemImage: "play.circle.fill")
                    }
                    .disabled(backupArguments(smoke: false) == nil
                              || ScriptLocator.backupScriptPath() == nil
                              || exportRunner.isRunning)

                    if let arguments = backupArguments(smoke: false),
                       let script = ScriptLocator.backupScriptPath() {
                        CopyButton(label: "Kopiraj naredbu",
                                   value: displayCommand(script: script, arguments: arguments))
                    }
                }

                ScriptRunnerStatusView(runner: exportRunner)
            }

            Divider()
            YouTubePrepSection(defaultInput: exportRunner.producedFile, runner: prepRunner)
        }
    }

    private func backupArguments(smoke: Bool) -> [String]? {
        guard !lumixVideos.isEmpty, !backupAudioWav.isEmpty, !backupOutputDir.isEmpty else { return nil }
        var arguments: [String] = []
        for video in lumixVideos { arguments += ["--camera", video] }
        arguments += ["--audio", backupAudioWav, "--output-dir", backupOutputDir]
        if backupLoudness { arguments.append("--loudness") }
        let start = backupStart.trimmingCharacters(in: .whitespaces)
        let end = backupEnd.trimmingCharacters(in: .whitespaces)
        if !start.isEmpty { arguments += ["--start", start] }
        if !end.isEmpty { arguments += ["--end", end] }
        if smoke { arguments.append("--smoke-test") }
        return arguments
    }

    private func runBackup(smoke: Bool) {
        guard let arguments = backupArguments(smoke: smoke),
              let script = ScriptLocator.backupScriptPath() else { return }
        exportRunner.run(script: script, arguments: arguments)
    }

    private func chooseBackupOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Odaberi izlaznu mapu"
        if panel.runModal() == .OK { backupOutputDir = panel.url?.path ?? "" }
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
        // All of this belongs to the session that was open a moment ago.
        //
        // Leaving it in place is what made switching takes look broken: the
        // player kept showing the previous session, because the view only
        // offers "Pripremi" while `preview` is nil and otherwise renders
        // whatever player it already has. The nudge was worse than cosmetic —
        // a non-nil `preview` is exactly what tells `rebuildPreview` to treat
        // the slider as an offset override, so the old take's correction would
        // have been applied to the new one.
        resetPreview()
        lumixVideos = []
        copied = false
        // Shown even when the load fails: the path that produced the error is
        // more use than "nije odabrana".
        manifestFolder = folder

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
            loadError = nil
        } catch {
            loadError = "Manifest se ne može pročitati: \(error.localizedDescription)"
            manifest = nil
        }
    }

    /// Drops every piece of lip-sync preview state, tearing down the player
    /// properly on the way out — the periodic time observer holds the player
    /// alive and keeps firing against a composition nobody is watching.
    private func resetPreview() {
        player?.pause()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
        preview = nil
        previewError = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        nudgeMilliseconds = 0
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
