import Foundation

/// Every clock sample this phone has taken, append-only on disk
/// (`Library/Application Support/clock-samples.txt`, one `t1 t4 s bootID` per line),
/// so a take's sidecar can carry samples from well before the take until its upload
/// ends, across reconnects and app relaunches. Samples from another boot are
/// useless (the host clock restarted); a take's samples are picked by offset
/// consistency (`ClockMath.sameBoot`). `bootID` only decides what is reloaded into
/// memory at launch.
///
/// Thread-safe: everything goes through one serial queue.
final class ClockLog {
    let url: URL
    let bootID: String
    private let queue = DispatchQueue(label: "tv.domovina.multicam.clocklog")
    /// This boot's samples from the last `memoryWindowNs`, for the start estimator.
    private var recent: [ClockSample] = []
    private let memoryWindowNs: Int64 = 30 * ClockMath.minute

    init(url: URL, bootID: String = HostClock.bootID, retainServerMs: Int64 = 7 * 24 * 3_600_000) {
        self.url = url
        self.bootID = bootID
        queue.sync {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let all = Self.parse(url)
            let now = HostClock.nowNs()
            recent = all.filter { $0.boot == bootID && now - $0.sample.t4 <= memoryWindowNs }.map(\.sample)
            // Drop what no sidecar could still need, keeping the file bounded
            // (one line per 5 s while connected ≈ 1.4 MB per day).
            if let newest = all.map(\.sample.s).max() {
                let kept = all.filter { newest - $0.sample.s <= retainServerMs }
                if kept.count < all.count { Self.rewrite(url, kept) }
            }
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("clock-samples.txt")
    }

    func append(_ sample: ClockSample) {
        queue.async {
            self.recent.append(sample)
            let cutoff = sample.t4 - self.memoryWindowNs
            if let first = self.recent.first, first.t4 < cutoff { self.recent.removeAll { $0.t4 < cutoff } }
            let line = Data("\(sample.t1) \(sample.t4) \(sample.s) \(self.bootID)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: self.url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: self.url)
            }
        }
    }

    func recentSamples() -> [ClockSample] { queue.sync { recent } }

    /// Samples sent at or after `fromNs` in the boot whose relay−host offset is
    /// `offsetMs` (see `ClockMath.sameBoot`), read from disk.
    func samples(offsetMs: Double, fromNs: Int64) -> [ClockSample] {
        queue.sync {
            ClockMath.window(ClockMath.sameBoot(Self.parse(url).map(\.sample), offsetMs: offsetMs), fromNs: fromNs)
        }
    }

    func count() -> Int { queue.sync { Self.parse(url).count } }

    private static func parse(_ url: URL) -> [(sample: ClockSample, boot: String)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(ClockSample, String)] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 4, let t1 = Int64(f[0]), let t4 = Int64(f[1]), let s = Int64(f[2]) else { continue }
            out.append((ClockSample(t1: t1, t4: t4, s: s), String(f[3])))
        }
        return out
    }

    private static func rewrite(_ url: URL, _ entries: [(sample: ClockSample, boot: String)]) {
        let text = entries.map { "\($0.sample.t1) \($0.sample.t4) \($0.sample.s) \($0.boot)\n" }.joined()
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}
