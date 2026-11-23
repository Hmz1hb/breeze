import CHardware
import Darwin
import FanCore
import Foundation
import IOKit.pwr_mgt
import os

// launchd discards the daemon's stderr; the unified log keeps restoration failures visible:
// log show --predicate 'subsystem == "local.breeze.fancontrol.helper"' --last 1h
private let logger = Logger(subsystem: "local.breeze.fancontrol.helper", category: "helper")

func report(_ text: String) {
    logger.error("\(text, privacy: .public)")
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Defers system sleep until the session loop has acted, so charging is paused before
/// the helper is suspended. The callback only records the request; the loop owns the SMC.
final class SleepWatcher: @unchecked Sendable {
    // IOKit message constants are C macros that do not import into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    nonisolated(unsafe) static var current: SleepWatcher?

    private let pending = OSAllocatedUnfairLock<Int?>(initialState: nil)
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init?() {
        root = IORegisterForSystemPower(nil, &port, { _, _, message, argument in
            guard let watcher = SleepWatcher.current else { return }
            let id = Int(bitPattern: argument)
            if message == SleepWatcher.canSystemSleep { IOAllowPowerChange(watcher.root, id) }
            else if message == SleepWatcher.systemWillSleep { watcher.pending.withLock { $0 = id } }
        }, &notifier)
        guard root != 0, let port else { return nil }
        IONotificationPortSetDispatchQueue(port, DispatchQueue(label: "local.breeze.fancontrol.sleep"))
        Self.current = self
    }

    /// Runs `prepare` and lets sleep continue, if a sleep is waiting.
    func handlePending(_ prepare: () -> Void) {
        guard let id = pending.withLock({ value -> Int? in defer { value = nil }; return value }) else { return }
        prepare()
        IOAllowPowerChange(root, id)
    }

    func close() {
        handlePending {}
        Self.current = nil
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(root)
        if let port { IONotificationPortDestroy(port) }
    }
}

func serve(_ fd: Int32, parent: pid_t, listener: Int32) throws {
    let smc = try SMC()
    defer {
        for attempt in 0..<10 {
            do { try smc.restoreAutomatic(); break }
            catch {
                report("Restoring Apple automatic control (attempt \(attempt+1)): \(error.localizedDescription)")
                usleep(200_000)
            }
        }
        // Reconnect the adapter before charging, so the Mac is never left on battery.
        for attempt in 0..<10 {
            do { try smc.restoreAdapter(); break }
            catch {
                report("Reconnecting the power adapter (attempt \(attempt+1)): \(error.localizedDescription)")
                usleep(200_000)
            }
        }
        // Never leave charging disabled after the session that requested it ends.
        for attempt in 0..<10 {
            do { try smc.restoreCharging(); break }
            catch {
                report("Re-enabling charging (attempt \(attempt+1)): \(error.localizedDescription)")
                usleep(200_000)
            }
        }
    }
    let sleepWatcher = SleepWatcher()
    defer { sleepWatcher?.close() }
    try Wire.send(Reply(ok: true, message: "Cooling helper connected.", manual: false), to: fd)
    var configuration = CoolingConfiguration()
    configuration.mode = .automatic
    var controller: CoolingController?
    var applied: Double?
    var boosted = false
    var suspended = false
    var status = "macOS manages cooling."
    var healthy = true
    var last = breeze_continuous_time()
    let powerReader = breeze_power_open()
    defer { breeze_power_close(powerReader) }
    var power: PrivilegedPower?
    var lastPower = 0.0
    func samplePower() {
        let now = breeze_continuous_time()
        guard let powerReader, now - lastPower >= 1 else { return }
        lastPower = now
        var raw = BreezePower()
        let result = breeze_power_sample(powerReader, &raw)
        if result == 0 { power = raw.cpu_watts > 0 ? PrivilegedPower(cpuWatts: raw.cpu_watts, aneWatts: raw.ane_watts, dramWatts: raw.dram_watts) : nil }
        else if result < 0 { power = nil }
    }
    var charger: ChargeController?
    var chargeStatus: String?
    var lastCharge = 0.0

    func applyCharging(force: Bool = false) {
        guard var active = charger else { return }
        let now = breeze_continuous_time()
        guard force || now - lastCharge >= 5 else { return }
        lastCharge = now
        let decision = active.next(BatteryState.read())
        charger = active
        do {
            if decision.allow == smc.chargingInhibited { try smc.setCharging(allowed: decision.allow) }
            chargeStatus = decision.message
            if decision.adapter == smc.adapterDisabled {
                do { try smc.setAdapter(enabled: decision.adapter) }
                catch {
                    // Unsupported or rejected adapter control ends discharge only; limiting continues.
                    active.stopDischarge()
                    charger = active
                    try? smc.restoreAdapter()
                    chargeStatus = "Discharge is unavailable on this Mac: \(error.localizedDescription)"
                    report(chargeStatus ?? "")
                }
            }
        } catch {
            // A failed charging write disables the limiter rather than retrying a contested key.
            charger = nil
            try? smc.restoreAdapter()
            do { try smc.restoreCharging(); chargeStatus = "\(error.localizedDescription) Charging is allowed." }
            catch let restore {
                chargeStatus = "\(error.localizedDescription) Re-enabling charging failed: \(restore.localizedDescription)"
                report(chargeStatus ?? "")
            }
        }
    }

    func applyController() throws {
        guard !suspended, configuration.mode != .automatic else { return }
        let snapshot = try smc.snapshot()
        guard var active = controller else { throw FanError("Cooling profile is unavailable.") }
        let decision = try active.next(snapshot: snapshot, now: breeze_continuous_time())
        controller = active
        if let applied { try smc.verifyManual(percent: applied) }
        if applied == nil || abs((applied ?? 0)-decision.percent) >= 1 {
            try smc.setManual(percent: decision.percent)
            applied = decision.percent
        }
        boosted = decision.boosted
        status = decision.message
    }
    func fail(_ error: any Error) {
        healthy = false
        status = error.localizedDescription
        configuration.mode = .automatic
        controller = nil
        applied = nil
        boosted = false
        do { try smc.restoreAutomatic(); status += " Returned to automatic control." }
        catch { status += " Restoration failed: \(error.localizedDescription)"; report(status) }
    }
    func reply() -> Reply {
        Reply(ok: healthy, message: status, manual: smc.hasOverrides, percent: applied,
              boosted: boosted, suspended: suspended, mode: configuration.mode,
              charging: chargeStatus, chargingPaused: smc.chargingInhibited,
              toppingUp: charger.map(\.isToppingUp), power: power)
    }

    while true {
        sleepWatcher?.handlePending {
            // With the adapter disconnected the Mac would drain overnight; reconnect it first.
            do { try smc.restoreAdapter() } catch { report("Reconnecting the adapter before sleep: \(error.localizedDescription)") }
            if charger?.configuration.pauseDuringSleep == true, !smc.chargingInhibited {
                do { try smc.setCharging(allowed: false); chargeStatus = "Charging paused for sleep." }
                catch { report("Pausing charging before sleep: \(error.localizedDescription)") }
            }
            lastCharge = 0 // Re-decide right after wake.
        }
        // One owner controls the hardware. Reject additional clients promptly.
        let waiting = breeze_accept(listener, 0)
        if waiting >= 0 {
            if breeze_authenticate_peer(waiting, HelperIdentity.app) == 0 {
                try? Wire.send(Reply(ok: false, message: "Another Breeze control session is already running.", manual: false), to: waiting)
            }
            close(waiting)
        }
        let command = try Wire.receive(Command.self, from: fd, timeout: 1000)
        let now = breeze_continuous_time()
        if breeze_stop_requested() != 0 || (!suspended && Safety.expired(last: last, now: now)) || kill(parent, 0) != 0 { return }
        if let command {
            last = now
            do {
                switch command.action {
                case .heartbeat: break
                case .charge:
                    // Charging errors never disturb an active cooling profile.
                    if let next = command.charge, next.isActive {
                        if let valid = try? ChargeController(configuration: next) {
                            charger = valid
                            applyCharging(force: true)
                        } else { chargeStatus = "Invalid charging settings were ignored." }
                    } else {
                        charger = nil
                        do { try smc.restoreAdapter(); try smc.restoreCharging(); chargeStatus = nil }
                        catch { chargeStatus = "Re-enabling charging failed: \(error.localizedDescription)"; report(chargeStatus ?? "") }
                    }
                case .configure, .manual:
                    var next: CoolingConfiguration
                    if command.action == .manual {
                        guard let value = command.percent else { throw FanError("A speed is required.") }
                        next = CoolingConfiguration(); next.mode = .manual; next.manualPercent = value
                    } else {
                        guard let supplied = command.configuration else { throw FanError("A cooling profile is required.") }
                        next = supplied
                    }
                    try next.validate()
                    configuration = next
                    controller = try CoolingController(configuration: next)
                    suspended = false; healthy = true; applied = nil; boosted = false
                    if next.mode == .automatic {
                        try smc.restoreAutomatic(adoptAll: true)
                        status = "macOS manages cooling."
                    }
                case .automatic, .quit:
                    configuration.mode = .automatic; controller = nil; applied = nil; boosted = false
                    try smc.restoreAutomatic(adoptAll: command.action == .automatic)
                    status = "macOS manages cooling."; healthy = true
                case .sleep:
                    suspended = true; applied = nil; boosted = false
                    try smc.restoreAutomatic()
                    status = "Cooling profile paused for sleep."; healthy = true
                case .wake:
                    if let profile = command.configuration {
                        try profile.validate()
                        configuration = profile
                    }
                    suspended = false; applied = nil
                    controller = try CoolingController(configuration: configuration)
                    healthy = true
                }
                try applyController()
            } catch { fail(error) }
            applyCharging()
            samplePower()
            try Wire.send(reply(), to: fd)
            last = breeze_continuous_time()
            if command.action == .quit { return }
        } else {
            do { try applyController() }
            catch { fail(error) }
            applyCharging()
            samplePower()
        }
    }

}

func run() throws {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--status" {
        let smc = try SMC()
        print(String(decoding: try JSONEncoder().encode(smc.snapshot()), as: UTF8.self))
        // Read-only: shows which charging and adapter keys this Mac's firmware exposes.
        let keys = try JSONSerialization.data(withJSONObject: ["chargingKeys": smc.chargingKeys(),
            "adapterControl": smc.adapterControl?.key ?? "unsupported"], options: [.sortedKeys])
        print(String(decoding: keys, as: UTF8.self))
        return
    }
    guard args.count == 2, args[1] == "--daemon", geteuid() == 0 else {
        throw FanError("Use --status to inspect hardware. The cooling helper is managed by macOS.")
    }
    let listener = breeze_activate_socket()
    guard listener >= 0 else { throw FanError("The cooling helper must be launched by macOS.") }
    defer { close(listener) }
    let lockFD = open("/var/run/com.local.breeze.fans.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else { throw FanError("Cannot create the fan session lock.") }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw FanError("Another Breeze helper is already running.") }
    breeze_install_signals()
    while breeze_stop_requested() == 0 {
        let fd = breeze_accept(listener, 1000)
        guard fd >= 0 else { continue }
        var uid: uid_t = 0, pid: pid_t = 0
        if breeze_peer(fd, &uid, &pid) == 0, uid > 0, pid > 1,
           breeze_authenticate_peer(fd, HelperIdentity.app) == 0 {
            do { try serve(fd, parent: pid, listener: listener) }
            catch { report(error.localizedDescription) }
        }
        close(fd)
    }
}

do { try run() }
catch { report(error.localizedDescription); exit(1) }
