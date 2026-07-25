import Foundation

/// Everything post-production needs to reassemble a session without guessing.
///
/// The manifest is the contract between the live recorder and `scripts/finalize_session.sh`.
/// Every track carries the host-clock timestamp of its first sample, so relative
/// offsets are exact. Drift (each USB mic runs on its own crystal) is measured
/// during the take and recorded here as a resample ratio.
struct SessionManifest: Codable {

    static let currentVersion = 1

    var version: Int = SessionManifest.currentVersion
    var sessionID: String
    var title: String
    var createdAt: Date
    var startedAtHostNanos: UInt64?
    var stoppedAtHostNanos: UInt64?
    var machine: MachineInfo
    var tracks: [Track] = []
    var events: [Event] = []
    var remote: RemoteInfo?

    /// Time series of the measured microphone→picture offset, sampled through
    /// the take. This is the number post-production must apply: the host clock
    /// only says when data reached the driver, and the video path is stamped
    /// 40–100 ms later than the audio path for the same real-world moment.
    /// Keeping the whole series (not just an average) is what lets post tell a
    /// constant offset from one that drifts across a 180-minute episode.
    var syncMeasurements: [SyncSample] = []

    var durationSeconds: Double? {
        guard let start = startedAtHostNanos, let stop = stoppedAtHostNanos, stop > start else { return nil }
        return Double(stop - start) / 1_000_000_000.0
    }

    struct MachineInfo: Codable {
        var hostName: String
        var osVersion: String
        var appVersion: String
    }

    struct RemoteInfo: Codable {
        var provider: String        // "cloudflare-r2"
        var bucket: String
        var prefix: String          // e.g. "sessions/2026-07-25-1930-epizoda-42"
    }

    enum TrackKind: String, Codable {
        /// One isolated microphone, written continuously as 24-bit WAV.
        case microphone
        /// Audio embedded in the HDMI feed (GH5 internal mic). Sync reference only.
        case cameraReferenceAudio
        /// The local high-quality capture of the HDMI feed.
        case cameraProxyVideo
        /// The camera's own SD-card recording, added during post.
        case cameraMasterVideo
    }

    struct Track: Codable, Identifiable {
        var id: String
        var kind: TrackKind
        var label: String
        var deviceName: String
        var deviceUID: String?

        /// Path relative to the session directory.
        var relativePath: String

        // Audio characteristics
        var sampleRate: Double?
        var channelCount: Int?
        var bitDepth: Int?

        // Video characteristics
        var codec: String?
        var width: Int?
        var height: Int?
        var nominalFrameRate: Double?

        /// Host-clock nanoseconds of the FIRST sample actually written.
        /// This is the value that makes lip sync exact.
        var firstSampleHostNanos: UInt64?
        var lastSampleHostNanos: UInt64?

        /// Frames (audio) or video frames written.
        var sampleCount: UInt64 = 0

        /// Sample rate as actually measured against the host clock. Divided by
        /// `sampleRate` this yields the resample ratio needed to remove the
        /// drift between this device's crystal and the system clock.
        var measuredSampleRate: Double?
        var driftPPM: Double?

        /// Chunks handed to the uploader, in order.
        var segments: [Segment] = []

        var clipCount: Int = 0
        var notes: String?

        /// Offset of this track relative to the session start, in seconds.
        /// Positive means the track starts *after* the session start marker.
        func offsetSeconds(relativeTo sessionStartHostNanos: UInt64) -> Double? {
            guard let first = firstSampleHostNanos else { return nil }
            if first >= sessionStartHostNanos {
                return Double(first - sessionStartHostNanos) / 1_000_000_000.0
            } else {
                return -Double(sessionStartHostNanos - first) / 1_000_000_000.0
            }
        }
    }

    struct Segment: Codable {
        var index: Int
        var relativePath: String?
        var remoteKey: String
        var byteCount: Int
        var startHostNanos: UInt64
        var durationSeconds: Double
        var uploaded: Bool = false
        var uploadedAt: Date?
    }

    struct SyncSample: Codable {
        var hostNanos: UInt64
        /// Positive means the camera feed (and therefore the picture) lags the
        /// microphones by this much, so the microphones need delaying by it.
        var offsetMilliseconds: Double
        /// Normalised correlation peak, 0...1. Only samples above ~0.3 mean anything.
        var confidence: Double
        /// What the raw host-clock timestamps claimed, kept for comparison.
        var clockOffsetMilliseconds: Double
    }

    /// Median of the confident measurements — robust to the stretches of silence
    /// where correlation is meaningless, unlike a mean.
    var resolvedSyncOffsetMilliseconds: Double? {
        let confident = syncMeasurements.filter { $0.confidence > 0.3 }.map(\.offsetMilliseconds).sorted()
        guard confident.count >= 3 else { return nil }
        let middle = confident.count / 2
        return confident.count.isMultiple(of: 2)
            ? (confident[middle - 1] + confident[middle]) / 2
            : confident[middle]
    }

    struct Event: Codable, Identifiable {
        enum Level: String, Codable { case info, warning, error }
        var id: String = UUID().uuidString
        var at: Date
        var hostNanos: UInt64
        var level: Level
        var message: String
        /// Marker events the host triggers by hand ("dobar dio", "ponovi ovo").
        var isMarker: Bool = false
    }

    mutating func upsert(track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
        } else {
            tracks.append(track)
        }
    }

    func track(withID id: String) -> Track? {
        tracks.first { $0.id == id }
    }
}
