import Foundation
import CoreMedia
import Darwin

/// The single time reference every recorder in the app stamps against.
///
/// `mach_absolute_time()` is the same clock that CoreAudio reports in
/// `AVAudioTime.hostTime` and that AVFoundation uses for capture-device sample
/// buffer presentation timestamps (`CMClockGetHostTimeClock`). Because both the
/// microphones and the Elgato capture feed are stamped on it, lip sync becomes
/// arithmetic instead of cross-correlation guesswork.
enum HostClock {

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Converts raw mach ticks to nanoseconds without overflowing on long sessions.
    static func nanos(fromHostTime hostTime: UInt64) -> UInt64 {
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        if numer == denom { return hostTime }
        let whole = hostTime / denom
        let remainder = hostTime % denom
        return whole * numer + (remainder * numer) / denom
    }

    static func hostTime(fromNanos nanos: UInt64) -> UInt64 {
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        if numer == denom { return nanos }
        let whole = nanos / numer
        let remainder = nanos % numer
        return whole * denom + (remainder * denom) / numer
    }

    /// Current time on the shared timeline, in nanoseconds.
    static func now() -> UInt64 {
        nanos(fromHostTime: mach_absolute_time())
    }

    static func seconds(fromHostTime hostTime: UInt64) -> Double {
        Double(nanos(fromHostTime: hostTime)) / 1_000_000_000.0
    }

    /// AVFoundation capture buffers carry a PTS already expressed on the host
    /// time clock, so this is a straight unit conversion.
    static func nanos(fromCaptureTime time: CMTime) -> UInt64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000.0)
    }

    /// Signed difference `a - b` in milliseconds, safe across UInt64 ordering.
    static func deltaMilliseconds(_ a: UInt64, _ b: UInt64) -> Double {
        if a >= b {
            return Double(a - b) / 1_000_000.0
        } else {
            return -Double(b - a) / 1_000_000.0
        }
    }
}
