import CoreMedia
import Darwin

/// The phone's monotonic clock, in nanoseconds: `mach_absolute_time` scaled by
/// `mach_timebase_info`. This is the same clock as `CMClockGetHostTimeClock()`,
/// which is what capture sample buffers are stamped with, so clock samples and
/// frame times can be compared directly (PROTOCOL.md, "Sat").
///
/// It does not survive a reboot, so everything persisted with it also carries
/// `bootID` and is only compared within one boot.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nowNs() -> Int64 { ns(fromTicks: mach_absolute_time()) }

    static func ns(fromTicks ticks: UInt64) -> Int64 {
        // Full-width multiply: ticks × numer cannot overflow.
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        let (q, _) = UInt64(timebase.denom).dividingFullWidth((high, low))
        return Int64(q)
    }

    /// A time on the host time clock (e.g. a converted sample-buffer PTS) in ns.
    static func ns(fromHostTime time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }

    static func hostTime(ns: Int64) -> CMTime {
        CMTime(value: ns, timescale: 1_000_000_000)
    }

    /// Changes on every boot; the host clock restarts with it.
    static let bootID: String = {
        var size = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 {
                let id = String(cString: buffer)
                if !id.isEmpty { return id }
            }
        }
        var boot = timeval()
        size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return "boottime-\(boot.tv_sec)"
    }()
}
