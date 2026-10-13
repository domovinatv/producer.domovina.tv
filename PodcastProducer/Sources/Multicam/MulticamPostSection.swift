import SwiftUI

/// Post: snimke telefona za odabranu sesiju. Preuzimaju se u `<sesija>/cameras/`,
/// a „Pokreni finalizaciju" ih odande sama poravna na miks (sync_cameras.py).
struct MulticamPostSection: View {
    var sessionID: String
    var sessionFolder: URL
    @StateObject private var downloader = MulticamDownloader()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Telefoni", systemImage: "iphone.gen3")
                    .font(.headline)
                if downloader.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    Task { await downloader.refresh(sessionID: sessionID) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(downloader.isBusy)
                .help("Ponovno pitaj relay što je stiglo")
            }

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            let missing = downloader.missing(in: sessionFolder)
            if !missing.isEmpty {
                Button {
                    Task { await downloader.download(sessionID: sessionID, sessionFolder: sessionFolder) }
                } label: {
                    Label("Preuzmi (\(missing.count), \(Self.megabytes(missing.reduce(0) { $0 + $1.size })))",
                          systemImage: "arrow.down.circle")
                }
                .disabled(downloader.isBusy)
            }
            if let progress = downloader.progress {
                Text(progress).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let problem = downloader.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .task(id: sessionFolder) { await downloader.refresh(sessionID: sessionID) }
    }

    private var summary: String {
        guard let remote = downloader.remote else {
            return downloader.problem == nil ? "Pitam relay…" : "Ne znam što je u R2."
        }
        let cameras = Set(remote.map { $0.relativePath.split(separator: "/").first.map(String.init) ?? "" })
        if remote.isEmpty { return "Za ovu sesiju nijedan telefon nije poslao snimku." }
        let missing = downloader.missing(in: sessionFolder).count
        let state = missing == 0 ? "sve je preuzeto u cameras/ — finalizacija ih poravnava sama" : "\(missing) datoteka još nije preuzeto"
        return "\(cameras.count) \(cameras.count == 1 ? "telefon" : "telefona") u R2, \(state)."
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes > 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}
