import Foundation

/// Owns the on-disk session folder and the manifest inside it.
///
/// The manifest is written atomically and re-written on every meaningful
/// change, so a crash mid-take still leaves a manifest describing everything
/// recorded up to that point.
final class SessionStore {

    enum StoreError: LocalizedError {
        case cannotCreateDirectory(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateDirectory(let path): return "Ne mogu kreirati mapu sesije: \(path)"
            }
        }
    }

    let rootURL: URL
    let audioURL: URL
    let videoURL: URL
    let segmentsURL: URL

    private var manifest: SessionManifest
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "tv.domovina.studio.manifest")
    private var savePending = false

    static var defaultLibraryURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("DomovinaStudio", isDirectory: true)
    }

    init(libraryURL: URL, title: String) throws {
        let stamp = SessionStore.timestampSlug()
        let slug = SessionStore.slugify(title)
        let folderName = slug.isEmpty ? stamp : "\(stamp)-\(slug)"

        rootURL = libraryURL.appendingPathComponent(folderName, isDirectory: true)
        audioURL = rootURL.appendingPathComponent("audio", isDirectory: true)
        videoURL = rootURL.appendingPathComponent("video", isDirectory: true)
        segmentsURL = rootURL.appendingPathComponent("segments", isDirectory: true)

        for url in [rootURL, audioURL, videoURL, segmentsURL] {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw StoreError.cannotCreateDirectory(url.path)
            }
        }

        manifest = SessionManifest(
            sessionID: folderName,
            title: title.isEmpty ? folderName : title,
            createdAt: Date(),
            machine: .init(
                hostName: ProcessInfo.processInfo.hostName,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: AppInfo.version
            )
        )
        saveNow()
    }

    var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }

    func snapshot() -> SessionManifest {
        lock.lock()
        defer { lock.unlock() }
        return manifest
    }

    func mutate(_ body: (inout SessionManifest) -> Void) {
        lock.lock()
        body(&manifest)
        lock.unlock()
        scheduleSave()
    }

    func log(_ message: String, level: SessionManifest.Event.Level = .info, isMarker: Bool = false) {
        mutate {
            $0.events.append(
                SessionManifest.Event(
                    at: Date(),
                    hostNanos: HostClock.now(),
                    level: level,
                    message: message,
                    isMarker: isMarker
                )
            )
        }
    }

    /// Coalesces bursts of manifest changes into one write per 500 ms.
    private func scheduleSave() {
        ioQueue.async { [weak self] in
            guard let self, !self.savePending else { return }
            self.savePending = true
            self.ioQueue.asyncAfter(deadline: .now() + 0.5) {
                self.savePending = false
                self.saveNow()
            }
        }
    }

    func saveNow() {
        lock.lock()
        let copy = manifest
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(copy) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    func relativePath(for url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    // MARK: - Naming

    private static func timestampSlug() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// `đ`/`Đ` are separate Latin letters rather than a base letter plus a
    /// combining mark, so `.diacriticInsensitive` folding leaves them intact.
    /// They have to be mapped by hand or they end up in folder names and, worse,
    /// in R2 object keys.
    private static let letterReplacements: [Character: String] = [
        "đ": "d", "Đ": "d", "ð": "d", "Ð": "d",
        "ł": "l", "Ł": "l", "ø": "o", "Ø": "o",
        "æ": "ae", "Æ": "ae", "œ": "oe", "Œ": "oe",
        "ß": "ss", "þ": "th", "Þ": "th"
    ]

    private static func slugify(_ input: String) -> String {
        let mapped = String(input.flatMap { character -> String in
            letterReplacements[character] ?? String(character)
        })
        let folded = mapped.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "hr_HR"))

        // Anything that is not a plain ASCII letter or digit becomes a hyphen,
        // which keeps the result safe for paths, URLs and shell arguments alike.
        let allowed = folded.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(48))
    }
}

enum AppInfo {
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
}
