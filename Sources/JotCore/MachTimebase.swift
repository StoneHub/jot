import Darwin

/// Converts Mach ticks to seconds. `proc_pid_rusage` counts CPU time in these ticks: a tick is one nanosecond on Intel and 125/3 nanoseconds on Apple Silicon.
public struct MachTimebase: Equatable, Sendable {
    public let numer: UInt32
    public let denom: UInt32

    /// This Mac's timebase.
    public static let current: MachTimebase = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MachTimebase(numer: info.numer, denom: info.denom)
    }()

    public func seconds(ticks: UInt64) -> Double {
        let nanoseconds = Double(ticks) * Double(numer) / Double(denom)
        return nanoseconds / 1_000_000_000
    }
}
