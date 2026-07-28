import Foundation

/// The "is this take actually safe?" panel.
///
/// Everything here exists because it has ruined a recording for somebody:
/// a full disk, a mic that silently stopped, a thermally throttled machine, or
/// an upload backlog that quietly grew until the session ended.
struct HealthReport: Equatable {

    enum Severity: Int, Comparable {
        case ok, warning, critical
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Item: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String
        var severity: Severity
    }

    var items: [Item] = []

    var worst: Severity { items.map(\.severity).max() ?? .ok }
    var isSafeToRecord: Bool { worst != .critical }
}

@MainActor
final class HealthMonitor {

    /// Hard floor. Below this the app refuses to start a new take rather than
    /// letting you discover the problem 40 minutes in.
    var minimumFreeGigabytes: Double = 20
    var warningFreeGigabytes: Double = 60

    private(set) var report = HealthReport()

    func evaluate(sessionDirectory: URL?,
                  estimatedGigabytesPerHour: Double,
                  microphones: [(label: String, levels: LevelMeter.Reading, isRunning: Bool)],
                  video: VideoCaptureController.Status?,
                  upload: UploadQueue.Stats,
                  isRecording: Bool,
                  elapsedSeconds: Double,
                  isBypassingRodeConnect: Bool = false) -> HealthReport {

        var items: [HealthReport.Item] = []

        // RØDE Connect is running, but the take is pointed at the raw microphones
        // behind it. That records without any of the gating the mixer exists for —
        // and with two PodMics a hand apart, the bleed it removes is the whole
        // reason it was switched on. Said rather than silently corrected: changing
        // which device a take records from is not a decision to make on someone's
        // behalf, least of all mid-session.
        if isBypassingRodeConnect {
            items.append(.init(
                id: "rode-topology",
                title: "RØDE Connect",
                detail: "radi, ali snimaju se sirovi mikrofoni — bez gatinga, s prelijevanjem. Prebaci slot na 'RØDE Connect Stream'.",
                severity: .warning
            ))
        }

        // Disk
        let target = sessionDirectory ?? SessionStore.defaultLibraryURL
        if let freeBytes = Self.availableBytes(at: target) {
            let freeGB = Double(freeBytes) / 1_073_741_824.0
            let hoursLeft = estimatedGigabytesPerHour > 0 ? freeGB / estimatedGigabytesPerHour : .infinity
            let severity: HealthReport.Severity =
                freeGB < minimumFreeGigabytes ? .critical :
                (freeGB < warningFreeGigabytes ? .warning : .ok)
            let hoursText = hoursLeft.isFinite ? String(format: "≈ %.1f h snimanja", hoursLeft) : "dovoljno"
            items.append(
                .init(
                    id: "disk",
                    title: "Slobodan prostor",
                    detail: String(format: "%.0f GB — %@", freeGB, hoursText),
                    severity: severity
                )
            )
        }

        // Microphones
        for microphone in microphones {
            if !microphone.isRunning {
                items.append(.init(id: "mic-\(microphone.label)", title: microphone.label,
                                   detail: "nije aktivan", severity: isRecording ? .critical : .warning))
            } else if microphone.levels.isSilent {
                items.append(.init(id: "mic-\(microphone.label)", title: microphone.label,
                                   detail: String(format: "tišina %.0f s — provjeri kabel", microphone.levels.silentSeconds),
                                   severity: .critical))
            } else if microphone.levels.clipCount > 0 {
                items.append(.init(id: "mic-\(microphone.label)", title: microphone.label,
                                   detail: "\(microphone.levels.clipCount)× clipping — spusti gain",
                                   severity: .warning))
            }
        }

        // Video
        if let video {
            if isRecording && video.videoFrameCount == 0 && elapsedSeconds > 3 {
                items.append(.init(id: "video", title: "Video", detail: "nema frameova s Elgata", severity: .critical))
            } else if video.droppedFrameCount > 0 {
                items.append(.init(id: "video-drops", title: "Video",
                                   detail: "\(video.droppedFrameCount) ispuštenih frameova",
                                   severity: video.droppedFrameCount > 30 ? .warning : .ok))
            }
            if let error = video.lastError {
                items.append(.init(id: "video-error", title: "Video greška", detail: error, severity: .critical))
            }
        }

        // Thermals — a throttled encoder shows up as dropped frames minutes later.
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            items.append(.init(id: "thermal", title: "Temperatura", detail: "Mac se grije — moguć throttling", severity: .warning))
        case .critical:
            items.append(.init(id: "thermal", title: "Temperatura", detail: "kritično — encoder će ispuštati frameove", severity: .critical))
        default:
            break
        }

        // Upload backlog
        if upload.isConfigured {
            if upload.failed > 0 {
                items.append(.init(id: "upload", title: "R2 upload",
                                   detail: "\(upload.failed) neuspješnih — \(upload.lastError ?? "")",
                                   severity: .warning))
            } else if upload.pendingBytes > 2_000_000_000 {
                items.append(.init(id: "upload", title: "R2 upload",
                                   detail: "zaostatak \(ByteCountFormatter.string(fromByteCount: Int64(upload.pendingBytes), countStyle: .file))",
                                   severity: .warning))
            }
        }

        report = HealthReport(items: items)
        return report
    }

    static func availableBytes(at url: URL) -> Int64? {
        var probe = url
        // Walk up until we hit something that exists — the session folder may
        // not be created yet when we are pre-flighting a take.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }

        let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])

        // `forImportantUsage` is the better number on APFS — it counts space
        // that purgeable caches would give back. But it is APFS/HFS+ only, and
        // on anything else (a plain exFAT recording drive, which is exactly
        // what gets carried between a Mac and a camera) it comes back as 0.
        // Trusting that 0 made the pre-flight refuse every take on an external
        // disk, which is the one place a three-hour episode actually belongs.
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let plain = values?.volumeAvailableCapacity, plain > 0 {
            return Int64(plain)
        }
        return nil
    }
}
