import Foundation

/// Lists the takes sitting in the session library, so post-production starts
/// from a list of recordings rather than from a file panel.
///
/// The library is the folder configured in Studio settings. It is normally on
/// an external drive, which is why nothing here throws on a missing folder: an
/// unmounted disk is a state to display, not an error to swallow.
enum SessionLibrary {

    /// One row: enough to recognise a take without opening it.
    struct Entry: Identifiable, Equatable {
        var id: String { url.path }
        let url: URL
        let title: String
        let recordedAt: Date
        let durationSeconds: Double?
        let trackCount: Int
        let hasVideo: Bool
        /// False when the folder holds a `manifest.json` that will not decode.
        /// Such a take is still listed — it is precisely the one someone needs
        /// to get at — but nothing beyond its folder name can be shown.
        let isReadable: Bool
    }

    struct Scan {
        var entries: [Entry] = []
        /// Set when the library itself could not be read, e.g. the drive that
        /// holds it is not mounted.
        var problem: String?
    }

    /// Reads the session folders, newest first.
    ///
    /// Ordered by the manifest's `createdAt`, not by folder name or file date.
    /// The folder name resolves only to the minute, so two takes started inside
    /// the same minute would sort arbitrarily; modification dates are worse
    /// still, because copying a library to another drive rewrites all of them
    /// and post-processing a take rewrites just one.
    ///
    /// Blocking on purpose — an external drive can take a moment. Callers run
    /// it off the main thread.
    static func scan(_ library: URL) -> Scan {
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: library.path, isDirectory: &isDirectory) else {
            return Scan(problem: "Mapa sesija nije dostupna: \(library.path)")
        }
        guard isDirectory.boolValue else {
            return Scan(problem: "Mapa sesija nije mapa: \(library.path)")
        }

        guard let children = try? fm.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Scan(problem: "Mapu sesija nije moguće pročitati: \(library.path)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entries = children.compactMap { folder -> Entry? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }

            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { return nil }

            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(SessionManifest.self, from: data) else {
                let fallback = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return Entry(url: folder,
                             title: folder.lastPathComponent,
                             recordedAt: fallback,
                             durationSeconds: nil,
                             trackCount: 0,
                             hasVideo: false,
                             isReadable: false)
            }

            return Entry(url: folder,
                         title: manifest.title,
                         recordedAt: manifest.createdAt,
                         durationSeconds: manifest.durationSeconds,
                         trackCount: manifest.tracks.count,
                         hasVideo: manifest.tracks.contains { $0.kind == .cameraProxyVideo },
                         isReadable: true)
        }
        .sorted { $0.recordedAt > $1.recordedAt }

        return Scan(entries: entries)
    }
}
