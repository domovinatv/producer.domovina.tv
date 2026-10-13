import CoreMedia
import XCTest

final class HostClockTests: XCTestCase {
    /// The clock samples (mach_absolute_time) and the capture PTS (host time clock)
    /// must be the same clock, or fileZeroDeviceNs means nothing.
    func testMachTimeIsTheCMHostTimeClock() {
        var worst: Int64 = 0
        for _ in 0..<1000 {
            let a = HostClock.nowNs()
            let cm = HostClock.ns(fromHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
            let b = HostClock.nowNs()
            XCTAssertLessThanOrEqual(a, b)
            worst = max(worst, abs(cm - (a + b) / 2) - (b - a) / 2)
        }
        XCTAssertLessThan(worst, 50_000, "host clock and mach time differ by \(worst) ns")
    }

    func testTickConversionMatchesCoreMedia() {
        let ticks = mach_absolute_time()
        let cm = HostClock.ns(fromHostTime: CMClockMakeHostTimeFromSystemUnits(ticks))
        XCTAssertLessThanOrEqual(abs(HostClock.ns(fromTicks: ticks) - cm), 1)
    }

    func testBootIDIsStable() {
        XCTAssertFalse(HostClock.bootID.isEmpty)
        XCTAssertEqual(HostClock.bootID, HostClock.bootID)
    }
}

final class ClockMathTests: XCTestCase {
    let ms: Int64 = 1_000_000
    let base: Int64 = 5_000_000_000_000   // host ns
    let server0: Int64 = 1_760_000_000_000 // relay ms at host `base`

    /// A sample whose true offset is server0 − base/1e6, with asymmetric delays.
    func sample(at hostNs: Int64, up: Int64, down: Int64) -> ClockSample {
        let t1 = hostNs
        let serverAt = t1 + up * ms
        return ClockSample(t1: t1, t4: serverAt + down * ms, s: server0 + (serverAt - base) / ms)
    }

    func testOffsetFromSymmetricSampleIsExact() {
        let s = sample(at: base, up: 20, down: 20)
        XCTAssertEqual(s.rttNs, 40 * ms)
        XCTAssertEqual(ClockMath.serverMs(atHostNs: base, using: s), Double(server0), accuracy: 0.001)
        XCTAssertEqual(ClockMath.hostNs(atServerMs: Double(server0) + 1000, using: s), base + 1000 * ms)
    }

    func testBestSampleIsMinimumRTTInRecentWindow() {
        let now = base + 30 * ClockMath.minute
        let old = sample(at: now - 20 * ClockMath.minute, up: 1, down: 1)   // best RTT, but stale
        let a = sample(at: now - 90_000 * ms, up: 30, down: 40)
        let b = sample(at: now - 60_000 * ms, up: 8, down: 9)
        let c = sample(at: now - 5_000 * ms, up: 50, down: 10)
        XCTAssertEqual(ClockMath.bestSample([old, a, b, c], nowNs: now), b)
        // Nothing in 2 min → widen to 10 min, then 60.
        XCTAssertEqual(ClockMath.bestSample([old], nowNs: now), old)
        XCTAssertNil(ClockMath.bestSample([old], nowNs: now + 2 * 60 * ClockMath.minute))
        XCTAssertNil(ClockMath.bestSample([], nowNs: now))
    }

    func testScheduledStartInTheFuture() {
        let now = base + 10_000 * ms
        let samples = [sample(at: now - 5_000 * ms, up: 15, down: 15)]
        let serverNow = Double(server0) + 10_000
        let (ns, basis) = ClockMath.startHostNs(startAtServerMs: serverNow + 2000, nowNs: now, samples: samples)
        XCTAssertNotNil(basis)
        XCTAssertEqual(ns, now + 2000 * ms)
    }

    func testScheduledStartInThePastIsImmediate() {
        let now = base + 10_000 * ms
        let samples = [sample(at: now - 5_000 * ms, up: 15, down: 15)]
        let (ns, _) = ClockMath.startHostNs(startAtServerMs: Double(server0) + 3_000, nowNs: now, samples: samples)
        XCTAssertEqual(ns, now)
    }

    func testScheduledStartWithoutSamplesIsImmediate() {
        let (ns, basis) = ClockMath.startHostNs(startAtServerMs: 9e12, nowNs: base, samples: [])
        XCTAssertEqual(ns, base)
        XCTAssertNil(basis)
    }

    func testAsymmetryErrorIsBoundedByHalfRTT() {
        // 5 ms up, 45 ms down: the midpoint assumption is off by (45−5)/2 = 20 ms ≤ RTT/2.
        let s = sample(at: base, up: 5, down: 45)
        let error = ClockMath.serverMs(atHostNs: base, using: s) - Double(server0)
        XCTAssertEqual(abs(error), 20, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(error), Double(s.rttNs) / 2e6)
    }

    func testWindowAndMergeDeduplicateByT1() {
        let a = ClockSample(t1: 10, t4: 20, s: 1), b = ClockSample(t1: 30, t4: 40, s: 2), c = ClockSample(t1: 50, t4: 60, s: 3)
        XCTAssertEqual(ClockMath.merge([a, b], [b, c, a]), [a, b, c])
        XCTAssertEqual(ClockMath.window([c, a, b], fromNs: 30), [b, c])
    }

    func testSampleJSONRoundTrip() throws {
        let s = ClockSample(t1: 1_234_567_890_123, t4: 1_234_597_890_123, s: 1_760_000_000_123)
        let data = try JSONSerialization.data(withJSONObject: s.json)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(ClockSample(json: back), s)
    }
}

final class TakeRulesTests: XCTestCase {
    func testStartIsIdempotentPerTakeId() {
        XCTAssertEqual(TakeRules.onStart(takeId: "a", current: "a", pending: nil, finished: [], stopping: false, cameraRunning: true), .ignoreDuplicate)
        XCTAssertEqual(TakeRules.onStart(takeId: "a", current: nil, pending: "a", finished: [], stopping: false, cameraRunning: false), .ignoreDuplicate)
        XCTAssertEqual(TakeRules.onStart(takeId: "a", current: nil, pending: nil, finished: ["a"], stopping: false, cameraRunning: true), .ignoreFinished)
        XCTAssertEqual(TakeRules.onStart(takeId: "b", current: "a", pending: nil, finished: [], stopping: false, cameraRunning: true), .replaceCurrent)
        XCTAssertEqual(TakeRules.onStart(takeId: "b", current: nil, pending: nil, finished: [], stopping: true, cameraRunning: true), .replaceCurrent)
        XCTAssertEqual(TakeRules.onStart(takeId: "b", current: nil, pending: nil, finished: [], stopping: false, cameraRunning: false), .deferUntilCameraReady)
        XCTAssertEqual(TakeRules.onStart(takeId: "b", current: nil, pending: nil, finished: [], stopping: false, cameraRunning: true), .startNow)
    }

    func testStopMatchesTake() {
        XCTAssertTrue(TakeRules.stopApplies(takeId: "", current: "a", pending: nil))
        XCTAssertTrue(TakeRules.stopApplies(takeId: "a", current: "a", pending: nil))
        XCTAssertTrue(TakeRules.stopApplies(takeId: "p", current: nil, pending: "p"))
        XCTAssertFalse(TakeRules.stopApplies(takeId: "old", current: "a", pending: nil))
    }

    func testStateStopsOnlyStaleRelayTakes() {
        let relayA = TakeRules.TakeRef(takeId: "a", fromRelay: true)
        let local = TakeRules.TakeRef(takeId: "local-1", fromRelay: false)
        XCTAssertEqual(TakeRules.onState(relayTakeId: nil, current: relayA, pending: nil).stopCurrent, true)
        XCTAssertEqual(TakeRules.onState(relayTakeId: "b", current: relayA, pending: nil).stopCurrent, true)
        XCTAssertEqual(TakeRules.onState(relayTakeId: "a", current: relayA, pending: nil).stopCurrent, false)
        XCTAssertEqual(TakeRules.onState(relayTakeId: nil, current: local, pending: nil).stopCurrent, false)
        XCTAssertEqual(TakeRules.onState(relayTakeId: nil, current: nil, pending: relayA).cancelPending, true)
        XCTAssertEqual(TakeRules.onState(relayTakeId: "a", current: nil, pending: relayA).cancelPending, false)
        XCTAssertEqual(TakeRules.onState(relayTakeId: nil, current: nil, pending: nil).stopCurrent, false)
    }
}

final class ClockLogTests: XCTestCase {
    func testAppendPersistsAndFiltersByBoot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clock-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = HostClock.nowNs()
        let log = ClockLog(url: url, bootID: "boot-A")
        for i in 0..<5 {
            log.append(ClockSample(t1: now + Int64(i) * 5_000_000_000, t4: now + Int64(i) * 5_000_000_000 + 30_000_000, s: 1_760_000_000_000 + Int64(i) * 5000))
        }
        XCTAssertEqual(log.recentSamples().count, 5)
        // A relaunch in another boot sees the file but not as "recent".
        let other = ClockLog(url: url, bootID: "boot-B")
        XCTAssertEqual(other.count(), 5)
        XCTAssertTrue(other.recentSamples().isEmpty)
        // Boot B: host clock restarted ~hours later, so its offset is far from A's.
        other.append(ClockSample(t1: 1_000_000, t4: 31_000_000, s: 1_760_000_000_000 + 3_600_000))
        let offsetA = ClockSample(t1: now, t4: now + 30_000_000, s: 1_760_000_000_000).offsetMs
        XCTAssertEqual(other.samples(offsetMs: offsetA, fromNs: now + 10_000_000_000).count, 3)
        XCTAssertEqual(other.samples(offsetMs: offsetA, fromNs: 0).count, 5)
        XCTAssertEqual(other.samples(offsetMs: Double(1_760_000_000_000 + 3_600_000) - 16, fromNs: 0).count, 1)
        // Relaunch in the same boot reloads recent samples from disk.
        XCTAssertEqual(ClockLog(url: url, bootID: "boot-A").recentSamples().count, 5)
    }

    func testRetentionDropsOldLines() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clock-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ClockLog(url: url, bootID: "x")
        log.append(ClockSample(t1: 1, t4: 2, s: 1_000))
        log.append(ClockSample(t1: 3, t4: 4, s: 1_000 + 8 * 24 * 3_600_000))
        XCTAssertEqual(log.count(), 2)
        XCTAssertEqual(ClockLog(url: url, bootID: "x").count(), 1)
    }
}
