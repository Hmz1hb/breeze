import CHardware
import Darwin
import Foundation

public enum SystemUptime {
    /// Time since boot, including sleep. ProcessInfo.systemUptime counts awake time only.
    public static var sinceBoot: TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}

public struct SystemStats: Sendable {
    public let cpuPercent: Double?
    public let memoryUsed: UInt64
    public let memoryTotal: UInt64
    public let uptime: TimeInterval
}

public struct SystemStatsReader {
    private var previous: [UInt64]?
    public init() {}
    public mutating func read() throws -> SystemStats {
        var ticks = [UInt64](repeating: 0, count: 4)
        var used: UInt64 = 0, total: UInt64 = 0
        guard breeze_system_stats(&ticks, &used, &total) == 0 else { throw FanError("System statistics are unavailable.") }
        var percent: Double?
        if let previous {
            let differences = zip(ticks, previous).map { UInt64(UInt32(truncatingIfNeeded: $0) &- UInt32(truncatingIfNeeded: $1)) }
            let sum = differences.reduce(0, +)
            if sum > 0 { percent = 100 * Double(sum-differences[2])/Double(sum) }
        }
        previous = ticks
        return SystemStats(cpuPercent: percent, memoryUsed: used, memoryTotal: total,
                           uptime: SystemUptime.sinceBoot)
    }
}
