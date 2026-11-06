import Foundation
import IOKit
import IOKit.ps
import Observation

struct BatteryReading: Sendable {
    enum Availability: Sendable { case available, noBattery, unavailable }
    var availability = Availability.unavailable
    var date = Date()
    var percent: Double?
    var externalConnected: Bool?
    var runningOnBattery: Bool?
    var charging: Bool?
    var fullyCharged: Bool?
    var condition: String?
    var reportedHealthPercent: Double?
    var serialNumber: String?
    var deviceName: String?
    var firmware: String?
    var cycles: Int?
    var designCapacity: Double?
    var fullChargeCapacity: Double?
    var nominalCapacity: Double?
    var remainingCapacity: Double?
    var temperature: Double?
    var voltage: Double?
    var amperage: Double?
    var adapterInputWatts: Double?
    var adapterInputVoltage: Double?
    var adapterInputCurrent: Double?
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var adapter: BatteryAdapter?

    /// A capacity-based estimate, not a claim about Apple's Battery Health algorithm.
    var healthPercent: Double? {
        if let reportedHealthPercent { return reportedHealthPercent }
        guard let designCapacity, let capacity = nominalCapacity ?? fullChargeCapacity else { return nil }
        return min(100, capacity / designCapacity * 100)
    }

    var batteryWatts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage / 1_000
    }

    var batteryFlowLabel: String {
        guard let watts = batteryWatts else { return "Unavailable" }
        let value = abs(watts).formatted(.number.precision(.fractionLength(1))) + " W"
        if abs(watts) < 0.05 { return "Idle · 0.0 W" }
        return watts > 0 ? "Charging · \(value)" : "Discharging · \(value)"
    }

    var status: String {
        if charging == true { return "Charging" }
        if externalConnected == true, runningOnBattery == true { return "Plugged in · Discharging" }
        if fullyCharged == true { return "Fully charged" }
        if externalConnected == true {
            if charging == false { return "Plugged in · Not charging" }
            return "Plugged in"
        }
        if externalConnected == false { return "On battery" }
        return "Status unavailable"
    }

    var timeTitle: String { charging == true ? "UNTIL FULL" : "TIME REMAINING" }
    var timeLabel: String {
        if fullyCharged == true { return "Fully charged" }
        if charging == true { return Self.duration(minutesToFull) ?? "Estimating…" }
        if runningOnBattery == true { return Self.duration(minutesToEmpty) ?? "Estimating…" }
        if externalConnected == true { return "External power" }
        return "Unavailable"
    }

    static func duration(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0, minutes < 65_535 else { return nil }
        if minutes < 60 { return "\(minutes) min" }
        let remainder = minutes % 60
        return "\(minutes / 60) hr" + (remainder == 0 ? "" : " \(remainder) min")
    }

    static func parse(source: [String: Any]?, registry: [String: Any]?, adapter: [String: Any]?,
                      sourcesReadable: Bool = true) -> BatteryReading {
        var result = BatteryReading()
        guard source != nil || registry != nil else {
            result.availability = sourcesReadable ? .noBattery : .unavailable
            return result
        }
        let source = source ?? [:]
        let registry = registry ?? [:]
        if source[kIOPSIsPresentKey] as? Bool == false || registry["BatteryInstalled"] as? Bool == false {
            result.availability = .noBattery
            return result
        }
        result.availability = .available
        let data = registry["BatteryData"] as? [String: Any] ?? [:]
        func number(_ dictionary: [String: Any], _ key: String) -> Double? {
            guard let value = dictionary[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            return number.isFinite ? number : nil
        }
        func positive(_ value: Double?) -> Double? { value.flatMap { $0 > 0 ? $0 : nil } }
        func capacity(_ key: String) -> Double? { positive(number(registry, key) ?? number(data, key)) }
        let current = number(source, kIOPSCurrentCapacityKey) ?? number(registry, "CurrentCapacity")
        let maximum = positive(number(source, kIOPSMaxCapacityKey) ?? number(registry, "MaxCapacity"))
        if let current, current >= 0, let maximum { result.percent = min(100, current / maximum * 100) }
        if let state = source[kIOPSPowerSourceStateKey] as? String {
            if state == kIOPSACPowerValue { result.runningOnBattery = false }
            if state == kIOPSBatteryPowerValue { result.runningOnBattery = true }
        }
        result.externalConnected = registry["ExternalConnected"] as? Bool ?? result.runningOnBattery.map { !$0 }
        result.runningOnBattery = result.runningOnBattery ?? result.externalConnected.map { !$0 }
        result.charging = source[kIOPSIsChargingKey] as? Bool ?? registry["IsCharging"] as? Bool
        result.fullyCharged = source[kIOPSIsChargedKey] as? Bool ?? registry["FullyCharged"] as? Bool
        result.condition = source[kIOPSBatteryHealthConditionKey] as? String ?? source[kIOPSBatteryHealthKey] as? String
        if result.condition == kIOPSGoodValue { result.condition = "Normal" }
        if let cycles = number(registry, "CycleCount") ?? number(data, "CycleCount"), (0...100_000).contains(cycles) {
            result.cycles = Int(cycles)
        }
        result.designCapacity = capacity("DesignCapacity")
        result.nominalCapacity = capacity("NominalChargeCapacity")
        result.fullChargeCapacity = capacity("AppleRawMaxCapacity") ?? capacity("FullChargeCapacity")
        // Older Intel batteries publish mAh here; Apple silicon usually publishes 100 (percent).
        if result.fullChargeCapacity == nil, let maximum = capacity("MaxCapacity"), maximum > 100 {
            result.fullChargeCapacity = maximum
        }
        let remaining = number(registry, "AppleRawCurrentCapacity") ?? number(data, "AppleRawCurrentCapacity")
        if let remaining, remaining >= 0 { result.remainingCapacity = remaining }
        if result.remainingCapacity == nil, result.fullChargeCapacity != nil,
           let maximum = number(registry, "MaxCapacity"), maximum > 100,
           let current = number(registry, "CurrentCapacity"), current >= 0 { result.remainingCapacity = current }
        if let raw = positive(number(registry, "Temperature")) {
            let celsius = raw / 100
            if (0...100).contains(celsius) { result.temperature = celsius }
        }
        if let millivolts = positive(number(registry, "Voltage")), millivolts < 100_000 {
            result.voltage = millivolts / 1_000
        }
        // Some drivers encode signed discharge current in an unsigned CFNumber.
        if let raw = (registry["Amperage"] ?? registry["InstantAmperage"]) as? NSNumber {
            let signed = raw.int64Value
            let value = signed > Int64(Int32.max) && signed <= Int64(UInt32.max)
                ? Double(Int32(bitPattern: UInt32(signed))) : Double(signed)
            if abs(value) < 100_000 { result.amperage = value }
        }
        func minutes(_ key: String) -> Int? {
            guard let value = number(source, key), value > 0, value < 65_535 else { return nil }
            return Int(value)
        }
        // Public IOPS estimates are minutes. Do not reuse firmware sentinel values as durations.
        if result.charging == true { result.minutesToFull = minutes(kIOPSTimeToFullChargeKey) }
        if result.runningOnBattery == true, result.charging == false {
            result.minutesToEmpty = minutes(kIOPSTimeToEmptyKey)
        }
        if result.externalConnected == true {
            // AppleSmartBattery input telemetry is mW, mV, and mA. These are
            // live DC readings at the Mac, separate from the adapter's rating.
            let telemetry = registry["PowerTelemetryData"] as? [String: Any] ?? [:]
            if let milliwatts = number(telemetry, "SystemPowerIn"), (0...1_000_000).contains(milliwatts) {
                result.adapterInputWatts = milliwatts / 1_000
            }
            if let millivolts = number(telemetry, "SystemVoltageIn"), (1...200_000).contains(millivolts) {
                result.adapterInputVoltage = millivolts / 1_000
            }
            if let milliamps = number(telemetry, "SystemCurrentIn"), (0...20_000).contains(milliamps) {
                result.adapterInputCurrent = milliamps / 1_000
            }
            var details = registry["AdapterDetails"] as? [String: Any] ?? [:]
            details.merge(adapter ?? [:]) { _, publicValue in publicValue }
            if !details.isEmpty { result.adapter = BatteryAdapter(details) }
        }
        return result
    }
}

struct BatteryAdapter: Sendable {
    var name: String?
    var manufacturer: String?
    var watts: Double?
    var voltage: Double?
    var current: Double?
    var model: String?
    var serial: String?
    var firmware: String?

    init(_ details: [String: Any]) {
        func text(_ key: String) -> String? {
            if let value = details[key] as? String, !value.isEmpty { return value }
            return (details[key] as? NSNumber)?.stringValue
        }
        func positive(_ key: String) -> Double? {
            guard let value = details[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
            return value.doubleValue
        }
        name = text("Name") ?? text("Description")
        manufacturer = text("Manufacturer")
        watts = positive(kIOPSPowerAdapterWattsKey)
        voltage = positive("AdapterVoltage").map { $0 / 1_000 }
        current = positive(kIOPSPowerAdapterCurrentKey).map { $0 / 1_000 }
        model = text("Model") ?? text(kIOPSPowerAdapterIDKey)
        serial = text("SerialString") ?? text(kIOPSPowerAdapterSerialNumberKey)
        firmware = text("FwVersion")
    }
}

struct BatteryHealthReport: Sendable {
    var condition: String?
    var maximumCapacity: Double?
    var serial: String?
    var device: String?
    var firmware: String?

    static func parse(_ data: Data) throws -> BatteryHealthReport {
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let battery = (report?["SPPowerDataType"] as? [[String: Any]])?.first { $0["_name"] as? String == "spbattery_information" }
        let health = battery?["sppower_battery_health_info"] as? [String: Any] ?? [:]
        let model = battery?["sppower_battery_model_info"] as? [String: Any] ?? [:]
        var result = BatteryHealthReport()
        result.condition = health["sppower_battery_health"] as? String
        if result.condition == "Good" { result.condition = "Normal" }
        if let text = health["sppower_battery_health_maximum_capacity"] as? String,
           let value = Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
           (0...100).contains(value) { result.maximumCapacity = value }
        result.serial = model["sppower_battery_serial_number"] as? String
        result.device = model["sppower_battery_device_name"] as? String
        result.firmware = model["sppower_battery_firmware_version"] as? String
        return result
    }

    func apply(to reading: inout BatteryReading) {
        reading.condition = reading.condition ?? condition
        reading.reportedHealthPercent = maximumCapacity
        reading.serialNumber = serial
        reading.deviceName = device
        reading.firmware = firmware
    }
}

enum BatteryReader {
    @concurrent static func health() async -> BatteryHealthReport? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-detailLevel", "mini", "-timeout", "5", "SPPowerDataType"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !Task.isCancelled else { return nil }
        return try? BatteryHealthReport.parse(data)
    }

    @concurrent static func read() async -> BatteryReading {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = info.flatMap { IOPSCopyPowerSourcesList($0)?.takeRetainedValue() as? [CFTypeRef] }
        let source = info.flatMap { info in
            sources?.compactMap { handle in
                IOPSGetPowerSourceDescription(info, handle)?.takeUnretainedValue() as? [String: Any]
            }.first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        var registry: [String: Any]?
        if service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                registry = properties?.takeRetainedValue() as? [String: Any]
            }
        }
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        return BatteryReading.parse(source: source, registry: registry, adapter: adapter,
                                    sourcesReadable: sources != nil && (service == 0 || registry != nil))
    }
}

@MainActor @Observable
final class BatteryModel {
    var reading: BatteryReading?
    var loading = false
    private var health: BatteryHealthReport?
    private var healthUpdated: Date?

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var result = await BatteryReader.read()
        guard !Task.isCancelled else { return }
        reading = result
        if result.availability == .available {
            if healthUpdated.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
                let report = await BatteryReader.health()
                guard !Task.isCancelled else { return }
                health = report
                healthUpdated = Date()
            }
            health?.apply(to: &result)
            reading = result
        } else { health = nil; healthUpdated = nil }
    }

    func run() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
        }
    }
}
