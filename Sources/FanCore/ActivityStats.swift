import CHardware
import Foundation
import IOKit

public struct CPUActivity: Sendable {
    public let user: Double
    public let system: Double
    public var used: Double { user + system }
    public var idle: Double { max(0, 100 - used) }

    /// Mach CPU counters are wrapping 32-bit ticks. A first sample has no interval.
    public static func between(_ current: [UInt64], and previous: [UInt64]?) -> CPUActivity? {
        guard current.count == 4, let previous, previous.count == 4 else { return nil }
        let delta = zip(current, previous).map { UInt64(UInt32(truncatingIfNeeded: $0) &- UInt32(truncatingIfNeeded: $1)) }
        let total = Double(delta.reduce(0, +))
        guard total > 0 else { return nil }
        return CPUActivity(user: Double(delta[0] + delta[3]) / total * 100, system: Double(delta[1]) / total * 100)
    }
}

public struct MemoryActivity: Sendable {
    public let total, app, wired, compressed, cached: UInt64
    public let swapUsed, swapTotal: UInt64?
    public let pressure: Int
    public var used: UInt64 { min(total, app + wired + compressed) }
    public var available: UInt64 { total - used }
    public var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

public struct GPUActivity: Sendable, Identifiable {
    public let id: UInt64
    public let name: String
    public let cores: Int?
    public let utilization, renderer, tiler: Double?
}

public struct ActivityProcess: Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let pid: Int32
        public let seconds, microseconds: UInt64
    }
    public let id: ID
    public var pid: Int32 { id.pid }
    public let name, user: String
    public let uid: UInt32
    public let cpu: Double?
    public let memory: UInt64?
    public let threads: Int?
    public let cpuTime: TimeInterval?

    public static func cpuPercent(current: UInt64, previous: UInt64?, elapsed: TimeInterval) -> Double? {
        guard let previous, current >= previous, elapsed > 0 else { return nil }
        return Double(current - previous) / (elapsed * 1_000_000_000) * 100
    }
}

public struct PowerActivity: Sendable {
    /// Nil when macOS withholds CPU energy from unprivileged readers (it then reports exactly 0).
    public var cpuWatts, aneWatts, dramWatts: Double?
    public let gpuWatts: Double
    /// Whole-Mac power from the SMC (PSTR), readable without privileges.
    public let systemWatts: Double?
    public let efficiencyMHz, performanceMHz, gpuMHz: Double?
    /// Fraction of time each cluster spent outside idle/off states, 0–1.
    public let efficiencyActive, performanceActive, gpuActive: Double?
    init(_ raw: BreezePower, systemWatts: Double?) {
        // An active CPU never uses exactly 0 J over a sample, so 0 means withheld.
        let cpuVisible = raw.cpu_watts > 0
        cpuWatts = cpuVisible ? raw.cpu_watts : nil
        aneWatts = cpuVisible ? raw.ane_watts : nil
        dramWatts = cpuVisible && raw.dram_watts > 0 ? raw.dram_watts : nil
        gpuWatts = raw.gpu_watts
        self.systemWatts = systemWatts
        func mhz(_ value: Double) -> Double? { value > 0 && value.isFinite ? value : nil }
        func fraction(_ value: Double) -> Double? { (0...1).contains(value) ? value : nil }
        efficiencyMHz = mhz(raw.ecpu_mhz); performanceMHz = mhz(raw.pcpu_mhz); gpuMHz = mhz(raw.gpu_mhz)
        efficiencyActive = fraction(raw.ecpu_active); performanceActive = fraction(raw.pcpu_active); gpuActive = fraction(raw.gpu_active)
    }
}

public struct ActivityReading: Sendable {
    public let date: Date
    public let cpu: CPUActivity?
    public let cores: [CPUActivity?]
    public let memory: MemoryActivity?
    public let gpus: [GPUActivity]
    public let load: [Double]
    public let processes: [ActivityProcess]?
    public let processError: String?
    public var power: PowerActivity? = nil
}

/// Separate from the cooling reader so process enumeration never delays its heartbeat.
public actor ActivityReader {
    private var ticks: [[UInt64]] = []
    private var processCPU: [ActivityProcess.ID: UInt64] = [:]
    private var processTime: TimeInterval?
    private var users: [UInt32: String] = [:]
    // Accessed only on the actor; nonisolated(unsafe) lets deinit release it.
    nonisolated(unsafe) private var power: UnsafeMutableRawPointer?
    private var powerUnavailable = false
    private var smc: SMC?
    private var smcUnavailable = false
    public init() {}
    deinit { breeze_power_close(power) }

    public func reset() {
        ticks = []; processCPU = [:]; processTime = nil
        breeze_power_close(power); power = nil
    }

    private func readPower() -> PowerActivity? {
        if power == nil && !powerUnavailable {
            power = breeze_power_open()
            powerUnavailable = power == nil
        }
        var raw = BreezePower()
        guard let power, breeze_power_sample(power, &raw) == 0, raw.has_energy != 0 else { return nil }
        if smc == nil && !smcUnavailable { smc = try? SMC(); smcUnavailable = smc == nil }
        let system = smc?.number("PSTR").flatMap { $0 > 0 && $0 < 2000 ? $0 : nil }
        return PowerActivity(raw, systemWatts: system)
    }

    public func read(includeProcesses: Bool) -> ActivityReading {
        var buffer = [UInt64](repeating: 0, count: 4 * 1024)
        let count = Int(breeze_core_ticks(&buffer, 1024))
        var cores: [CPUActivity?] = []
        var cpu: CPUActivity?
        if count > 0 {
            let current = (0..<count).map { Array(buffer[($0 * 4)..<($0 * 4 + 4)]) }
            cores = current.enumerated().map { CPUActivity.between($0.element, and: ticks.indices.contains($0.offset) ? ticks[$0.offset] : nil) }
            if ticks.count == current.count {
                let valid = cores.compactMap { $0 }
                if valid.count == count {
                    cpu = CPUActivity(user: valid.map(\.user).reduce(0, +) / Double(count),
                                      system: valid.map(\.system).reduce(0, +) / Double(count))
                }
            }
            ticks = current
        } else { ticks = [] }
        var raw = BreezeMemory()
        let memory: MemoryActivity? = breeze_memory(&raw) == 0 ? MemoryActivity(
            total: raw.total, app: raw.app, wired: raw.wired, compressed: raw.compressed, cached: raw.cached,
            swapUsed: raw.swap_valid != 0 ? raw.swap_used : nil, swapTotal: raw.swap_valid != 0 ? raw.swap_total : nil, pressure: Int(raw.pressure)) : nil
        var load = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&load, 3)
        var processes: [ActivityProcess]?
        var error: String?
        if includeProcesses {
            var rows = [BreezeProcess](repeating: BreezeProcess(), count: 16384)
            let now = ProcessInfo.processInfo.systemUptime
            let n = Int(breeze_processes(&rows, Int32(rows.count)))
            if n >= 0 {
                var next: [ActivityProcess.ID: UInt64] = [:]
                processes = rows.prefix(n).map { row in
                    let id = ActivityProcess.ID(pid: row.pid, seconds: row.start_seconds, microseconds: row.start_microseconds)
                    var chars = row.name
                    let name = withUnsafeBytes(of: &chars) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if users[row.uid] == nil {
                        users[row.uid] = getpwuid(row.uid).map { String(cString: $0.pointee.pw_name) } ?? String(row.uid)
                    }
                    let percent = row.has_task != 0 ? ActivityProcess.cpuPercent(current: row.cpu_ns, previous: processCPU[id], elapsed: now - (processTime ?? now)) : nil
                    if row.has_task != 0 { next[id] = row.cpu_ns }
                    return ActivityProcess(id: id, name: name, user: users[row.uid] ?? String(row.uid), uid: row.uid,
                        cpu: percent, memory: row.footprint > 0 ? row.footprint : (row.has_task != 0 ? row.resident : nil),
                        threads: row.has_task != 0 ? Int(row.threads) : nil,
                        cpuTime: row.has_task != 0 ? Double(row.cpu_ns) / 1_000_000_000 : nil)
                }
                processCPU = next; processTime = now
            } else {
                error = "macOS could not provide the process list. Try resuming monitoring."
                processCPU = [:]; processTime = nil
            }
        } else { processCPU = [:]; processTime = nil }
        return ActivityReading(date: Date(), cpu: cpu, cores: cores, memory: memory, gpus: readGPUs(),
                               load: loadCount > 0 ? Array(load.prefix(Int(loadCount))) : [], processes: processes, processError: error,
                               power: readPower())
    }

    private func readGPUs() -> [GPUActivity] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [GPUActivity] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            let stats = property("PerformanceStatistics") as? [String: Any] ?? [:]
            func percent(_ key: String) -> Double? {
                guard let value = (stats[key] as? NSNumber)?.doubleValue, value.isFinite, (0...100).contains(value) else { return nil }
                return value
            }
            let rawName = property("model")
            let name: String
            if let text = rawName as? String { name = text }
            else if let data = rawName as? Data { name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
            else { name = "Graphics processor" }
            result.append(GPUActivity(id: id, name: name, cores: (property("gpu-core-count") as? NSNumber)?.intValue,
                utilization: percent("Device Utilization %"), renderer: percent("Renderer Utilization %"), tiler: percent("Tiler Utilization %")))
        }
        return result
    }
}

public enum ActivityHardware {
    public static func string(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    public static func integer(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
