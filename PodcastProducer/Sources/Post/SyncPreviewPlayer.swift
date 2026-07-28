import Foundation
import SwiftUI
import AVFoundation

/// Plays the composition through an `AVPlayerLayer`.
///
/// Deliberately not SwiftUI's `VideoPlayer`. That lives in AVKit, reached through
/// the `_AVKit_SwiftUI` cross-import overlay, and in this SwiftPM-built binary
/// the overlay loads but cannot resolve its superclass metadata — the app died
/// on `getSuperclassMetadata` the moment the view was built, before a frame was
/// ever drawn. `AVPlayerLayer` is plain AVFoundation, which is already linked,
/// so nothing has to be inferred at runtime.
struct SyncPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) nije podržan") }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}

/// Builds a playable composition of the take with lip sync already applied, so
/// it can be judged before anything is rendered.
///
/// Nothing here is encoded: `AVMutableComposition` places the proxy's picture
/// and the isolated microphone tracks on one timeline and AVPlayer resolves it
/// live. Checking sync therefore costs seconds instead of the length of a
/// finalize run — which matters, because the answer to "is it right?" decides
/// whether you run finalize at all.
///
/// The same three corrections the finalize script applies are applied here, in
/// the same order, so what you see is what you will get:
///
/// 1. each microphone's start offset, from `firstSampleHostNanos`
/// 2. each microphone's clock drift, as a time scale
/// 3. the measured microphone→picture offset
enum SyncPreviewPlayer {

    struct Result {
        var composition: AVMutableComposition
        var appliedOffsetMilliseconds: Double
        var hasVideo: Bool
        var microphoneCount: Int
        /// Worth showing: these are the corrections, spelled out.
        var notes: [String]
    }

    enum PreviewError: LocalizedError {
        case noPlayableTracks
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noPlayableTracks: return "Sesija nema ni sliku ni zvuk koji se mogu reproducirati."
            case .unreadable(let name): return "Ne mogu pročitati \(name)."
            }
        }
    }

    /// - Parameter offsetOverrideMilliseconds: nudge value from the UI. Nil uses
    ///   what the take measured, which is the number finalize would apply.
    static func build(manifest: SessionManifest,
                      sessionURL: URL,
                      offsetOverrideMilliseconds: Double? = nil) async throws -> Result {

        let composition = AVMutableComposition()
        var notes: [String] = []

        let offsetMilliseconds = offsetOverrideMilliseconds
            ?? manifest.resolvedSyncOffsetMilliseconds
            ?? 0

        // MARK: Picture

        var hasVideo = false
        var anchorHostNanos: UInt64?

        if let proxy = manifest.tracks.first(where: { $0.kind == .cameraProxyVideo }) {
            let url = sessionURL.appendingPathComponent(proxy.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                if let source = try await asset.loadTracks(withMediaType: .video).first,
                   let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let duration = try await asset.load(.duration)
                    try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
                    hasVideo = true
                    // Everything else is positioned against the first video frame,
                    // the same anchor finalize_session.sh uses.
                    anchorHostNanos = proxy.firstSampleHostNanos
                    notes.append("slika: \(proxy.width ?? 0)×\(proxy.height ?? 0) proxy")
                }
            }
        }

        if !hasVideo {
            notes.append("⚠️ sesija nema video — čuje se samo zvuk")
        }

        // Audio-only takes still deserve a player, anchored on the session start.
        let anchor = anchorHostNanos ?? manifest.startedAtHostNanos ?? 0

        // MARK: Microphones

        var microphoneCount = 0

        for track in manifest.tracks where track.kind == .microphone {
            let url = sessionURL.appendingPathComponent(track.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }

            let duration = try await asset.load(.duration)

            // 1. Where this microphone started relative to the picture.
            var startSeconds = track.offsetSeconds(relativeTo: anchor) ?? 0

            // 3. The capture pipeline stamps the picture later than the sound for
            //    the same moment, so a positive measurement means the microphones
            //    have to be pushed back by it.
            startSeconds += offsetMilliseconds / 1000.0

            // A microphone that started before the camera cannot be placed at a
            // negative time; trim its head instead, which is the same thing.
            let sourceStart = startSeconds < 0 ? CMTime(seconds: -startSeconds, preferredTimescale: 48000) : .zero
            let insertAt = startSeconds < 0 ? CMTime.zero : CMTime(seconds: startSeconds, preferredTimescale: 48000)
            let usable = CMTimeSubtract(duration, sourceStart)
            guard usable > .zero else { continue }

            try target.insertTimeRange(CMTimeRange(start: sourceStart, duration: usable), of: source, at: insertAt)

            // 2. Drift: the crystal ran slightly slow or fast, so the track has to
            //    be stretched onto the host clock's timeline. Scaling the whole
            //    range is the single-ratio correction — the piecewise version
            //    lives in finalize, and over a preview the two are
            //    indistinguishable.
            if let nominal = track.sampleRate, let measured = track.measuredSampleRate,
               nominal > 0, measured > 0 {
                let ratio = nominal / measured
                // Guard against a nonsense measurement, same 500 ppm bound the
                // finalize script uses.
                if abs(ratio - 1) < 0.0005 {
                    let scaled = CMTimeMultiplyByFloat64(usable, multiplier: ratio)
                    target.scaleTimeRange(CMTimeRange(start: insertAt, duration: usable), toDuration: scaled)
                }
            }

            microphoneCount += 1
            notes.append(String(format: "%@: %+.0f ms start%@",
                                track.label,
                                (track.offsetSeconds(relativeTo: anchor) ?? 0) * 1000,
                                track.driftPPM.map { String(format: ", %+.1f ppm drift", $0) } ?? ""))
        }

        guard hasVideo || microphoneCount > 0 else { throw PreviewError.noPlayableTracks }

        if microphoneCount == 0 {
            notes.append("⚠️ nema izoliranih mikrofona — čuje se zvuk iz kamere")
        } else if hasVideo {
            // The camera's own audio would fight the microphones; it was only ever
            // a sync reference.
            notes.append(String(format: "primijenjen pomak: %+.0f ms", offsetMilliseconds))
        }

        return Result(
            composition: composition,
            appliedOffsetMilliseconds: offsetMilliseconds,
            hasVideo: hasVideo,
            microphoneCount: microphoneCount,
            notes: notes
        )
    }
}
