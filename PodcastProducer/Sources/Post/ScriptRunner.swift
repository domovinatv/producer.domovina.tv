import Foundation

/// Runs one post-production shell script at a time and republishes its output
/// as it arrives.
///
/// This is the first place the app spawns a child process. The scripts stay
/// the single source of truth for ffmpeg invocations — everything in
/// `scripts/` was verified on real episodes, and duplicating those command
/// lines in Swift would mean two copies drifting apart. The app's job is only
/// to launch, show and stop them.
@MainActor
final class ScriptRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var logText = ""
    @Published private(set) var launchError: String?

    /// The last `✅ Za upload:`/`✅ Finalna snimka:` path the script printed,
    /// so the UI can offer "reveal in Finder" and feed the next step.
    @Published private(set) var producedFile: String?

    private var process: Process?
    private var lines: [String] = []
    private var partialLine = ""

    var succeeded: Bool { exitCode == 0 }
    var finished: Bool { exitCode != nil }

    func run(script: String, arguments: [String]) {
        guard !isRunning else { return }
        isRunning = true
        exitCode = nil
        launchError = nil
        producedFile = nil
        lines = []
        partialLine = ""
        logText = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + arguments

        // Launched from Finder the app inherits a bare PATH (/usr/bin:/bin) —
        // no Homebrew (ffmpeg), no python.org framework (modal,
        // audio-offset-finder), no ~/.local/bin (claude). All verified
        // locations on this machine, extended rather than replaced.
        var environment = ProcessInfo.processInfo.environment
        var extra = ["/opt/homebrew/bin", "/usr/local/bin",
                     NSHomeDirectory() + "/.local/bin"]
        let pythonVersions = "/Library/Frameworks/Python.framework/Versions"
        for version in (try? FileManager.default.contentsOfDirectory(atPath: pythonVersions)) ?? []
        where version != "Current" {
            extra.append("\(pythonVersions)/\(version)/bin")
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = (extra + [path]).joined(separator: ":")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Lossy decoding on purpose: a read can split a multi-byte character
            // (the scripts print emoji), and dropping the whole chunk would lose
            // log lines. A rare replacement character in the tail is fine.
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.append(text) }
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.flushPartial()
                self.exitCode = finished.terminationStatus
                self.isRunning = false
                self.process = nil
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            launchError = "Skripta se ne može pokrenuti: \(error.localizedDescription)"
            isRunning = false
            exitCode = -1
        }
    }

    func cancel() {
        process?.terminate()
    }

    // MARK: - Log assembly

    /// ffmpeg's `-stats` progress redraws its line with carriage returns; a
    /// plain append would either flood the log or interleave garbage. `\r`
    /// therefore restarts the current line, `\n` commits it.
    private func append(_ chunk: String) {
        for character in chunk {
            switch character {
            case "\n":
                commit(partialLine)
                partialLine = ""
            case "\r":
                partialLine = ""
            default:
                partialLine.append(character)
            }
        }
        publish()
    }

    private func flushPartial() {
        if !partialLine.isEmpty {
            commit(partialLine)
            partialLine = ""
        }
        publish()
    }

    private func commit(_ line: String) {
        lines.append(line)
        // "Za upload" (YouTube pass) wins over "Finalna snimka" (mastering mux)
        // when a run prints both; the smoke-test clip counts too.
        if let range = line.range(of: "✅ Za upload: ") {
            producedFile = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if let range = line.range(of: "✅ Isječak: ") {
            producedFile = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if producedFile == nil, let range = line.range(of: "✅ Finalna snimka: ") {
            producedFile = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }

    private func publish() {
        // The full log already lands in the script's own log file on disk;
        // the view only needs a readable tail.
        var tail = lines.suffix(400).joined(separator: "\n")
        if !partialLine.isEmpty {
            tail += (tail.isEmpty ? "" : "\n") + partialLine
        }
        logText = tail
    }
}
