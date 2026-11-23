import Foundation
import IOKit

/// Charge limiting runs in the helper only while a Breeze control session is connected.
/// Ending the session always re-enables charging.
public struct ChargeConfiguration: Codable, Equatable, Sendable {
    public var enabled = false
    public var limit: Double = 80
    /// Charging resumes only after the battery falls this far below the limit.
    public var sailing: Double = 5
    public var heatProtection = false
    public var heatLimit: Double = 35
    // New options are optional so settings saved by earlier versions still decode.
    /// Charge to 100% once; the limit returns when the adapter is unplugged. Not saved across launches.
    public var topUp: Bool?
    /// Inhibit charging just before the Mac sleeps, so it can't charge past the limit while asleep.
    public var pauseDuringSleep: Bool?
    /// Run from the battery while plugged in until it falls to the limit.
    public var discharge: Bool?
    public init() {}

    public var isActive: Bool { enabled || heatProtection }

    public func validate() throws {
        guard limit.isFinite, (50...100).contains(limit), sailing.isFinite, (0...20).contains(sailing),
              heatLimit.isFinite, (30...45).contains(heatLimit) else {
            throw FanError("Choose a charge limit of 50–100%, a sailing range of 0–20% and a heat limit of 30–45°C.")
        }
        guard !(topUp == true && discharge == true) else { throw FanError("Top up and discharge can’t run at the same time.") }
    }
}

public struct BatteryState: Sendable {
    public let percent: Double?
    public let temperature: Double?
    public let externalConnected: Bool
    public init(percent: Double?, temperature: Double?, externalConnected: Bool) {
        self.percent = percent; self.temperature = temperature; self.externalConnected = externalConnected
    }

    public static func read() -> BatteryState? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.doubleValue
        }
        var percent: Double?
        if let current = number("CurrentCapacity"), let maximum = number("MaxCapacity"), maximum > 0, current >= 0 {
            percent = min(100, current / maximum * 100)
        }
        let temperature = number("Temperature").map { $0 / 100 }.flatMap { (0...100).contains($0) ? $0 : nil }
        let external = IORegistryEntryCreateCFProperty(service, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
        return BatteryState(percent: percent, temperature: temperature, externalConnected: external)
    }
}

public struct ChargeDecision: Equatable, Sendable {
    public let allow: Bool
    public let message: String
    /// False while discharging: the Mac runs from its battery with the adapter connected.
    public var adapter = true
}

/// Pure decision logic with hysteresis; the helper owns the SMC writes.
public struct ChargeController: Sendable {
    public private(set) var configuration: ChargeConfiguration
    private var holding = false
    private var hot = false
    private var discharging = false
    private var topUpEnded = false
    public private(set) var isToppingUp = false

    public init(configuration: ChargeConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
    }

    /// Used when the firmware rejects adapter control: keep limiting, stop discharging.
    public mutating func stopDischarge() {
        configuration.discharge = nil
        discharging = false
    }

    public mutating func next(_ battery: BatteryState?) -> ChargeDecision {
        guard configuration.isActive else { isToppingUp = false; return ChargeDecision(allow: true, message: "macOS manages charging.") }
        // Missing readings must never leave charging or the adapter disabled.
        guard let battery, let percent = battery.percent else {
            holding = false; hot = false; discharging = false
            return ChargeDecision(allow: true, message: "Battery reading unavailable: charging is allowed.")
        }
        let limit = Int(configuration.limit), resume = Int(configuration.limit - configuration.sailing)
        if configuration.topUp == true, !battery.externalConnected { topUpEnded = true }
        isToppingUp = configuration.enabled && configuration.topUp == true && !topUpEnded
        if configuration.enabled, configuration.discharge == true {
            // Start one point above the limit so readings that hover at it don't toggle the adapter.
            if percent >= configuration.limit + 1 { discharging = true }
            else if percent <= configuration.limit { discharging = false }
        } else { discharging = false }
        if configuration.heatProtection, let temperature = battery.temperature {
            if temperature >= configuration.heatLimit { hot = true }
            else if temperature <= configuration.heatLimit - 2 { hot = false }
        } else { hot = false }
        if configuration.enabled, !isToppingUp {
            if percent >= configuration.limit { holding = true }
            else if percent <= configuration.limit - configuration.sailing { holding = false }
        } else { holding = false }

        let message: String
        if hot {
            message = "Battery is \(Int(battery.temperature ?? 0))°C: charging paused until it cools by 2°C."
        } else if discharging {
            message = "Running on battery to bring it down to \(limit)%. The adapter reconnects at the limit."
        } else if isToppingUp {
            message = percent >= 100 ? "Topped up to 100%. The \(limit)% limit returns when you unplug." : "Topping up to 100%. The \(limit)% limit returns when you unplug."
        } else if holding {
            message = configuration.sailing > 0
                ? "Holding at \(limit)%. Charging resumes below \(resume)%."
                : "Holding at \(limit)%."
        } else if configuration.enabled {
            message = battery.externalConnected ? "Charging to \(limit)%." : "On battery. Charging will stop at \(limit)%."
        } else {
            message = "Heat protection is watching the battery temperature."
        }
        return ChargeDecision(allow: !(hot || holding), message: message, adapter: !discharging)
    }
}
