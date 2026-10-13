import Foundation

/// One `time` round trip (PROTOCOL.md, "Sat"): `t1`/`t4` on the host clock (ns) when
/// the probe left and its reply arrived, `s` the relay's clock (ms) in between.
struct ClockSample: Equatable {
    var t1: Int64
    var t4: Int64
    var s: Int64

    var rttNs: Int64 { t4 - t1 }

    /// Relay ms minus host ms, assuming the relay answered at the midpoint.
    var offsetMs: Double { Double(s) - Double(t1 + t4) / 2 / 1_000_000 }

    var json: [String: Any] { ["t1": t1, "t4": t4, "s": s] }

    init(t1: Int64, t4: Int64, s: Int64) {
        self.t1 = t1
        self.t4 = t4
        self.s = s
    }

    init?(json: [String: Any]) {
        guard let t1 = (json["t1"] as? NSNumber)?.int64Value,
              let t4 = (json["t4"] as? NSNumber)?.int64Value,
              let s = (json["s"] as? NSNumber)?.int64Value else { return nil }
        self.init(t1: t1, t4: t4, s: s)
    }
}

enum ClockMath {
    static let minute: Int64 = 60_000_000_000

    /// The sample to trust for "what time is it on the relay": the smallest RTT
    /// among recent samples. Recent first (drift of a phone crystal is ~10–20 ppm,
    /// i.e. ~1 ms per minute at worst), widening only if there is nothing recent.
    static func bestSample(_ samples: [ClockSample], nowNs: Int64,
                           windows: [Int64] = [2 * minute, 10 * minute, 60 * minute]) -> ClockSample? {
        for window in windows {
            let recent = samples.filter { $0.t4 <= nowNs && nowNs - $0.t4 <= window && $0.rttNs > 0 }
            if let best = recent.min(by: { $0.rttNs < $1.rttNs }) { return best }
        }
        return nil
    }

    static func serverMs(atHostNs ns: Int64, using sample: ClockSample) -> Double {
        Double(ns) / 1_000_000 + sample.offsetMs
    }

    static func hostNs(atServerMs ms: Double, using sample: ClockSample) -> Int64 {
        Int64(((ms - sample.offsetMs) * 1_000_000).rounded())
    }

    /// When (host ns) to begin a take scheduled for `startAtServerMs`. Never in the
    /// past: a late start (late join, reconnect mid-take) begins immediately.
    static func startHostNs(startAtServerMs: Double, nowNs: Int64, samples: [ClockSample]) -> (ns: Int64, basis: ClockSample?) {
        guard let best = bestSample(samples, nowNs: nowNs) else { return (nowNs, nil) }
        return (max(nowNs, hostNs(atServerMs: startAtServerMs, using: best)), best)
    }

    /// Samples whose send time is at or after `fromNs`, ordered and de-duplicated
    /// by `t1` (a sample is uniquely identified by when it was sent).
    static func window(_ samples: [ClockSample], fromNs: Int64, toNs: Int64 = .max) -> [ClockSample] {
        merge([], samples.filter { $0.t1 >= fromNs && $0.t1 <= toNs })
    }

    /// Samples from the same boot as a reference offset. The host clock restarts at
    /// boot, so relay−host offsets of two boots differ by the time between those
    /// boots, while within a boot they move only by drift (ppm) and network
    /// asymmetry (ms). This does not depend on a boot identifier, which iOS only
    /// offers as `kern.boottime` — and that shifts when the wall clock is stepped.
    static func sameBoot(_ samples: [ClockSample], offsetMs reference: Double, toleranceMs: Double = 300_000) -> [ClockSample] {
        samples.filter { abs($0.offsetMs - reference) < toleranceMs }
    }

    static func merge(_ a: [ClockSample], _ b: [ClockSample]) -> [ClockSample] {
        var byT1: [Int64: ClockSample] = [:]
        for sample in a + b { byT1[sample.t1] = sample }
        return byT1.values.sorted { $0.t1 < $1.t1 }
    }
}

/// The take decisions, kept free of AVFoundation so they can be unit-tested.
/// PROTOCOL.md: `start` is idempotent per takeId, `stop` is a no-op when nothing
/// matches, a `state` that no longer lists our relay take stops it, and losing the
/// connection itself never stops anything.
enum TakeRules {
    enum StartDecision: Equatable {
        case ignoreDuplicate      // already armed/recording/waiting for this takeId
        case ignoreFinished       // this takeId was already recorded on this phone
        case replaceCurrent       // another take is running: stop it, then start this one
        case deferUntilCameraReady
        case startNow
    }

    static func onStart(takeId: String, current: String?, pending: String?, finished: Set<String>,
                        stopping: Bool, cameraRunning: Bool) -> StartDecision {
        if current == takeId || pending == takeId { return .ignoreDuplicate }
        if finished.contains(takeId) { return .ignoreFinished }
        if current != nil || stopping { return .replaceCurrent }
        return cameraRunning ? .startNow : .deferUntilCameraReady
    }

    /// A `stop` names a take (or "" for whatever is running). A stop for some
    /// other, stale take must not end the one that is running now.
    static func stopApplies(takeId: String, current: String?, pending: String?) -> Bool {
        takeId.isEmpty || takeId == current || takeId == pending
    }

    struct TakeRef: Equatable { var takeId: String; var fromRelay: Bool }

    /// `state` arrives on every (re)connect with the relay's current take or nil.
    static func onState(relayTakeId: String?, current: TakeRef?, pending: TakeRef?) -> (stopCurrent: Bool, cancelPending: Bool) {
        let stop = current.map { $0.fromRelay && $0.takeId != relayTakeId } ?? false
        let cancel = pending.map { $0.fromRelay && $0.takeId != relayTakeId } ?? false
        return (stop, cancel)
    }
}
