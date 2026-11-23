import Foundation

public struct Fan: Identifiable, Codable, Sendable {
    public let id: Int
    public let current: Double
    public let minimum: Double
    public let maximum: Double
    public let target: Double?
    public let mode: Double?
    public var controllable: Bool { maximum > minimum && maximum <= 20000 && minimum >= 0 && mode != nil }
    public var name: String { "Fan \(id + 1)" }
    public var isManual: Bool { mode == 1 }
}

public struct Temperature: Codable, Sendable {
    public let key: String
    public let celsius: Double
}

public struct Snapshot: Codable, Sendable {
    public let fans: [Fan]
    public let temperatures: [Temperature]
    public let thermalPressure: String
    public var hottest: Double? { temperatures.map(\.celsius).max() }
    public var canControl: Bool { !fans.isEmpty && fans.allSatisfy(\.controllable) }
    public var cpuTemperature: Double? { temperatures.filter { !$0.key.hasPrefix("Tg") }.map(\.celsius).max() }
    public var gpuTemperature: Double? { temperatures.filter { $0.key.hasPrefix("Tg") }.map(\.celsius).max() }
}

public struct FanError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Safety {
    public static let heartbeatLimit = 6.0
    public static func target(percent: Double, minimum: Double, maximum: Double) throws -> Double {
        guard percent.isFinite, (0...100).contains(percent), minimum.isFinite, maximum.isFinite,
              minimum >= 0, maximum > minimum, maximum <= 20000 else {
            throw FanError("Invalid fan range or speed.")
        }
        // Never deliberately stop a fan, even when the firmware reports a zero minimum.
        let floor = max(minimum, min(1200, maximum))
        return (floor + (maximum-floor) * percent/100).rounded()
    }
    public static func check(_ snapshot: Snapshot) throws {
        guard snapshot.canControl else { throw FanError("A supported fan with valid RPM limits is required.") }
    }
    public static func expired(last: Double, now: Double) -> Bool {
        now - last > heartbeatLimit || now < last
    }
}

public struct Command: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case heartbeat, manual, configure, automatic, sleep, wake, quit, charge }
    public let action: Action
    public let percent: Double?
    public let configuration: CoolingConfiguration?
    public let charge: ChargeConfiguration?
    public init(_ action: Action, percent: Double? = nil, configuration: CoolingConfiguration? = nil,
                charge: ChargeConfiguration? = nil) {
        self.action = action; self.percent = percent; self.configuration = configuration; self.charge = charge
    }
}

public struct Reply: Codable, Sendable {
    public let ok: Bool
    public let message: String
    public let manual: Bool
    public let percent: Double?
    public let boosted: Bool
    public let suspended: Bool
    public let mode: CoolingMode
    /// Charge limiter status; nil while macOS manages charging.
    public let charging: String?
    public let chargingPaused: Bool?
    /// IOReport CPU energy, which recent macOS shares only with privileged readers.
    public let power: PrivilegedPower?
    public init(ok: Bool, message: String, manual: Bool, percent: Double? = nil,
                boosted: Bool = false, suspended: Bool = false, mode: CoolingMode = .automatic,
                charging: String? = nil, chargingPaused: Bool? = nil, power: PrivilegedPower? = nil) {
        self.ok = ok; self.message = message; self.manual = manual
        self.percent = percent; self.boosted = boosted; self.suspended = suspended; self.mode = mode
        self.charging = charging; self.chargingPaused = chargingPaused; self.power = power
    }
}

public struct PrivilegedPower: Codable, Sendable {
    public let cpuWatts: Double
    public let aneWatts: Double
    public let dramWatts: Double
    public init(cpuWatts: Double, aneWatts: Double, dramWatts: Double) {
        self.cpuWatts = cpuWatts; self.aneWatts = aneWatts; self.dramWatts = dramWatts
    }
}
