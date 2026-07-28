import SwiftUI
import UniformTypeIdentifiers

/// What `scripts/prepare_youtube.sh` writes into `youtube_metadata.json`.
struct YouTubeMetadata: Decodable {
    struct Chapter: Decodable {
        var time: String
        var topic: String
    }

    var titleOptions: [String]
    var description: String
    var chapters: [Chapter]
    var tags: [String]

    enum CodingKeys: String, CodingKey {
        case titleOptions = "title_options"
        case description, chapters, tags
    }
}

/// "Priprema za YouTube": transcription on Modal + AI-generated title,
/// description, chapters and tags — everything YouTube Studio asks for at
/// upload time. The catalog pipeline in fetch.domovina.tv still runs after
/// upload; this covers only what must exist *before* it.
struct YouTubePrepSection: View {
    /// The file the export step just produced, offered as the default input.
    var defaultInput: String?

    @ObservedObject var runner: ScriptRunner

    @State private var inputPath = ""
    @State private var titleHint = ""
    @State private var metadata: YouTubeMetadata?
    @State private var metadataError: String?

    private var effectiveInput: String {
        inputPath.isEmpty ? (defaultInput ?? "") : inputPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Priprema za YouTube (AI)", systemImage: "sparkles.tv")
                .font(.headline)
            Text("Transkripcija na Modalu (Canary, isti model kao u katalogu), govornici lokalno (pyannote), pa naslov, opis, poglavlja i tagovi iz transkripta. Radi na gotovoj datoteci — ništa ne dira sliku ni zvuk.")
                .font(.caption)
                .foregroundStyle(.secondary)

            FileField(label: "Finalna datoteka", path: Binding(
                get: { effectiveInput },
                set: { inputPath = $0 }
            ), types: [.movie, .quickTimeMovie, .mpeg4Movie, .wav])

            HStack {
                Text("Radni naslov")
                    .frame(width: 180, alignment: .trailing)
                    .font(.callout)
                TextField("neobavezno — tema epizode, pomaže kod naslova", text: $titleHint)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }

            HStack {
                Button {
                    start()
                } label: {
                    Label("Pripremi metapodatke", systemImage: "wand.and.stars")
                }
                .disabled(effectiveInput.isEmpty || runner.isRunning)

                if metadata != nil {
                    Button("Osvježi (ponovno generiraj)") { start(force: true) }
                        .disabled(runner.isRunning)
                }
            }

            ScriptRunnerStatusView(runner: runner)
                .onChange(of: runner.exitCode) {
                    if runner.succeeded { loadMetadata() }
                }

            if let metadataError {
                Text(metadataError).font(.caption).foregroundStyle(.red)
            }

            if let metadata {
                resultView(metadata)
            }
        }
        .onAppear(perform: loadMetadata)
    }

    // MARK: - Actions

    private func start(force: Bool = false) {
        guard let script = ScriptLocator.prepareYouTubeScriptPath() else {
            metadataError = "Nema scripts/prepare_youtube.sh — provjeri instalaciju."
            return
        }
        metadata = nil
        metadataError = nil
        var arguments = ["--input", effectiveInput]
        let hint = titleHint.trimmingCharacters(in: .whitespaces)
        if !hint.isEmpty { arguments += ["--title-hint", hint] }
        if force { arguments += ["--force-metadata"] }
        runner.run(script: script, arguments: arguments)
    }

    /// The script writes next to the input file, so the result is findable on
    /// re-open even if it was generated in an earlier run (or by hand).
    private func loadMetadata() {
        guard !effectiveInput.isEmpty else { return }
        let url = URL(fileURLWithPath: effectiveInput)
            .deletingLastPathComponent()
            .appendingPathComponent("youtube_metadata.json")
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            metadata = try JSONDecoder().decode(YouTubeMetadata.self, from: data)
            metadataError = nil
        } catch {
            metadataError = "youtube_metadata.json se ne može pročitati: \(error.localizedDescription)"
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultView(_ metadata: YouTubeMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Naslov (odaberi jedan)").font(.callout.weight(.medium))
                ForEach(Array(metadata.titleOptions.enumerated()), id: \.offset) { _, title in
                    HStack(alignment: .top, spacing: 8) {
                        Text(title)
                            .font(.callout)
                            .textSelection(.enabled)
                        Spacer()
                        Text("\(title.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(title.count > 100 ? .red : .secondary)
                            .help("Broj znakova (YouTube limit je 100)")
                        CopyButton(label: "Kopiraj", value: title)
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Opis (s poglavljima)").font(.callout.weight(.medium))
                    Spacer()
                    CopyButton(label: "Kopiraj opis", value: metadata.description)
                }
                ScrollView {
                    Text(metadata.description)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tagovi").font(.callout.weight(.medium))
                    Text(metadata.tags.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                CopyButton(label: "Kopiraj tagove", value: metadata.tags.joined(separator: ", "))
            }

            DisclosureGroup("Poglavlja (\(metadata.chapters.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(metadata.chapters.enumerated()), id: \.offset) { _, chapter in
                        HStack {
                            Text(chapter.time)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(chapter.topic).font(.caption)
                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
