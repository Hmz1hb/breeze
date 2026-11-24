import CHardware
import Foundation

public final class SMC {
    private var connection: UInt32 = 0
    private var temperatureKeys: [String] = []
    private var modeKeys: [Int: String] = [:]
    private var touched: Set<Int> = []
    private var testModeChanged = false
    public var hasOverrides: Bool { !touched.isEmpty || testModeChanged }

    public init() throws {
        let result = breeze_smc_open(&connection)
        guard result == 0 else { throw FanError("Cannot open AppleSMC (\(result)). This Mac or macOS version may be unsupported.") }
        discoverTemperatures()
    }
    deinit { breeze_smc_close(connection) }

    private func raw(_ key: String) throws -> (String, [UInt8]) {
        var type: UInt32 = 0, size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = breeze_smc_read(connection, key, &type, &size, &bytes)
        guard result == 0 else { throw FanError("AppleSMC could not read \(key) (\(result)).") }
        let name = String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: type >> (24-$0*8)) }, encoding: .ascii) ?? ""
        return (name, Array(bytes.prefix(Int(size))))
    }
    public func number(_ key: String) -> Double? {
        guard let (type, bytes) = try? raw(key) else { return nil }
        return SMCCodec.decode(bytes, type: type)
    }
    private func write(_ key: String, value: Double) throws {
        let (type, old) = try raw(key)
        let bytes = try SMCCodec.encode(value, type: type, size: old.count)
        let result = breeze_smc_write(connection, key, UInt32(bytes.count), bytes)
        guard result == 0 else { throw FanError("AppleSMC rejected \(key) (\(result)). macOS may be keeping control.") }
    }
    private func modeKey(_ id: Int) -> String? {
        if let key = modeKeys[id] { return key }
        for key in ["F\(id)md", "F\(id)Md"] where number(key) != nil {
            modeKeys[id] = key
            return key
        }
        return nil
    }
    private func discoverTemperatures() {
        // Die sensors only; ambient and battery sensors cannot guard manual CPU cooling.
        if let count = number("#KEY"), count > 0, count <= 20000 {
            for index in 0..<UInt32(count) {
                var bytes = [CChar](repeating: 0, count: 5)
                if breeze_smc_key(connection, index, &bytes) == 0 {
                    let key = String(decoding: bytes.prefix(4).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tg") || key.hasPrefix("TC") {
                        temperatureKeys.append(key)
                    }
                }
            }
        }
        if temperatureKeys.isEmpty {
            temperatureKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Te05", "Te0L", "Tg05", "Tg0D", "TC0P", "TC0D"]
        }
        temperatureKeys = temperatureKeys.filter { key in
            guard let t = number(key) else { return false }
            return (5...125).contains(t)
        }
    }
    public func snapshot() throws -> Snapshot {
        guard let count = number("FNum"), count >= 0, count <= 10, count.rounded() == count else {
            throw FanError("This Mac does not expose a supported fan inventory.")
        }
        let fans = try (0..<Int(count)).map { id -> Fan in
            guard let current = number("F\(id)Ac"), current >= 0, current <= 20000 else {
                throw FanError("Fan \(id+1) stopped reporting its speed.")
            }
            return Fan(id: id, current: current, minimum: number("F\(id)Mn") ?? -1,
                       maximum: number("F\(id)Mx") ?? -1, target: number("F\(id)Tg"),
                       mode: modeKey(id).flatMap { number($0) })
        }
        let temps = temperatureKeys.compactMap { key -> Temperature? in
            guard let value = number(key), (5...125).contains(value) else { return nil }
            return Temperature(key: key, celsius: value)
        }
        let pressure: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: pressure = "nominal"
        case .fair: pressure = "fair"
        case .serious: pressure = "serious"
        case .critical: pressure = "critical"
        @unknown default: pressure = "critical"
        }
        return Snapshot(fans: fans, temperatures: temps, thermalPressure: pressure)
    }
    public func setManual(percent: Double) throws {
        let state = try snapshot()
        try Safety.check(state)
        // Validate every target before touching any fan.
        let targets = try state.fans.map { try Safety.target(percent: percent, minimum: $0.minimum, maximum: $0.maximum) }
        do {
            for (fan, target) in zip(state.fans, targets) {
                guard let key = modeKey(fan.id) else { throw FanError("Fan mode is unavailable.") }
                touched.insert(fan.id) // Include partially written fans in rollback.
                if number(key) != 1 {
                  do {
                    try WriteVerification.apply(attempts: 5, write: { try self.write(key, value: 1) },
                                                matches: { self.number(key) == 1 }, pause: { usleep(100_000) })
                  }
                catch {
                    // Older Apple silicon may require Ftst before accepting manual mode.
                    guard let test = number("Ftst"), test == 0 || testModeChanged else { throw error }
                    testModeChanged = true
                    try write("Ftst", value: 1)
                    usleep(3_000_000)
                    try WriteVerification.apply(attempts: 10, write: { try self.write(key, value: 1) },
                                                matches: { self.number(key) == 1 }, pause: { usleep(100_000) })
                }
                }
                try WriteVerification.apply(attempts: 5, write: { try self.write("F\(fan.id)Tg", value: target) },
                                            matches: {
                    guard self.number(key) == 1, let readback = self.number("F\(fan.id)Tg") else { return false }
                    return abs(readback-target) <= 2
                }, pause: { usleep(100_000) })
            }
            // High temperature must never hand cooling back to a quieter system profile.
        } catch {
            do { try restoreAutomatic() }
            catch let restore { throw FanError("\(error.localizedDescription) Restoration also failed: \(restore.localizedDescription)") }
            throw error
        }
    }
    public func verifyManual(percent: Double) throws {
        let state = try snapshot()
        try Safety.check(state)
        for fan in state.fans {
            let desired = try Safety.target(percent: percent, minimum: fan.minimum, maximum: fan.maximum)
            guard fan.isManual, let target = fan.target, abs(target-desired) <= 2 else {
                throw FanError("Firmware changed the fan mode or target. Breeze could not retain its override.")
            }
        }
    }
    public func restoreAutomatic(adoptAll: Bool = false) throws {
        if adoptAll {
            for fan in try snapshot().fans where fan.isManual { touched.insert(fan.id) }
        }
        var failures: [String] = []
        // Only restore fans touched by this session; never alter another utility on launch.
        for id in touched.sorted() {
            do {
                guard let key = modeKey(id) else { throw FanError("Missing mode key for fan \(id+1).") }
                try WriteVerification.apply(attempts: 5, write: { try self.write(key, value: 0) },
                                            matches: { self.number(key) == 0 || self.number(key) == 3 },
                                            pause: { usleep(100_000) })
                // A zero target is the Apple silicon automatic sentinel, not a manual zero RPM.
                try write("F\(id)Tg", value: 0)
                guard let mode = number(key), mode == 0 || mode == 3 else {
                    throw FanError("Automatic mode was not retained for fan \(id+1).")
                }
                touched.remove(id)
            } catch { failures.append(error.localizedDescription) }
        }
        if testModeChanged && touched.isEmpty {
            do { try write("Ftst", value: 0); testModeChanged = false }
            catch { failures.append(error.localizedDescription) }
        }
        guard failures.isEmpty else { throw FanError(failures.joined(separator: " ")) }
    }

    public private(set) var chargingInhibited = false

    /// Apple silicon firmware since macOS 15 uses CHTE (4 bytes); earlier firmware uses CH0B/CH0C (1 byte).
    /// Writes raw bytes because these keys are flags, not numbers, and verifies each readback.
    public func setCharging(allowed: Bool) throws {
        var writes: [(String, [UInt8])] = []
        if let (_, bytes) = try? raw("CHTE"), bytes.count == 4 {
            writes = [("CHTE", [allowed ? 0 : 1, 0, 0, 0])]
        } else if let (_, bytes) = try? raw("CH0B"), bytes.count == 1 {
            writes = [("CH0B", [allowed ? 0 : 2])]
            if let (_, other) = try? raw("CH0C"), other.count == 1 { writes.append(("CH0C", [allowed ? 0 : 2])) }
        } else {
            throw FanError("This Mac’s firmware doesn’t expose a supported charging control.")
        }
        if !allowed { chargingInhibited = true } // Include partial writes in restoration.
        for (key, value) in writes {
            try WriteVerification.apply(attempts: 3, write: {
                let result = breeze_smc_write(self.connection, key, UInt32(value.count), value)
                guard result == 0 else { throw FanError("AppleSMC rejected \(key) (\(result)).") }
            }, matches: { (try? self.raw(key))?.1 == value }, pause: { usleep(100_000) })
        }
        chargingInhibited = !allowed
    }

    public func restoreCharging() throws {
        guard chargingInhibited else { return }
        try setCharging(allowed: true)
    }

    public private(set) var adapterDisabled = false

    /// Whether charging can be paused directly. macOS 27-era firmware gates these keys
    /// (and bfF0/bfD0/bfE0) behind an Apple entitlement; only the adapter key stays open.
    public var canInhibitCharging: Bool {
        (try? raw("CHTE"))?.1.count == 4 || (try? raw("CH0B"))?.1.count == 1
    }

    /// CHIE (1 byte, 0x08 disconnects) on current firmware, CH0I (1 byte, 0x01) on earlier firmware.
    /// CH0J is deliberately unsupported: open-source tools disagree on its value.
    public var adapterControl: (key: String, off: UInt8)? {
        if let (_, bytes) = try? raw("CHIE"), bytes.count == 1 { return ("CHIE", 0x08) }
        if let (_, bytes) = try? raw("CH0I"), bytes.count == 1 { return ("CH0I", 0x01) }
        return nil
    }

    public func setAdapter(enabled: Bool) throws {
        guard let control = adapterControl else {
            throw FanError("This Mac’s firmware doesn’t expose a supported adapter control.")
        }
        let value: [UInt8] = [enabled ? 0 : control.off]
        if !enabled { adapterDisabled = true } // Include partial writes in restoration.
        try WriteVerification.apply(attempts: 3, write: {
            let result = breeze_smc_write(self.connection, control.key, 1, value)
            guard result == 0 else { throw FanError("AppleSMC rejected \(control.key) (\(result)).") }
        }, matches: { (try? self.raw(control.key))?.1 == value }, pause: { usleep(100_000) })
        adapterDisabled = !enabled
    }

    public func restoreAdapter() throws {
        guard adapterDisabled else { return }
        try setAdapter(enabled: true)
    }

    public private(set) var magSafeLEDOverridden = false

    /// MagSafe 3 Macs expose ACLC (1 byte). Other Macs and gated firmware don't.
    public var magSafeLED: UInt8? {
        guard let (_, bytes) = try? raw("ACLC"), bytes.count == 1 else { return nil }
        return bytes[0]
    }

    /// 0 returns the light to macOS; see `MagSafeLED` for the others.
    public func setMagSafeLED(_ value: UInt8) throws {
        guard magSafeLED != nil else { throw FanError("This Mac doesn’t expose a MagSafe light control.") }
        if value != 0 { magSafeLEDOverridden = true } // Include partial writes in restoration.
        try WriteVerification.apply(attempts: 3, write: {
            let result = breeze_smc_write(self.connection, "ACLC", 1, [value])
            guard result == 0 else { throw FanError("AppleSMC rejected ACLC (\(result)).") }
        }, matches: { self.magSafeLED == value }, pause: { usleep(100_000) })
        magSafeLEDOverridden = value != 0
    }

    public func restoreMagSafeLED() throws {
        guard magSafeLEDOverridden else { return }
        try setMagSafeLED(0)
    }

    /// Read-only probe for `--status`: which charging keys exist and their sizes in bytes.
    public func chargingKeys() -> [String: Int] {
        var keys: [String: Int] = [:]
        for key in ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "bfF0", "bfD0", "bfE0", "ACLC"] {
            if let (_, bytes) = try? raw(key) { keys[key] = bytes.count }
        }
        return keys
    }
}
