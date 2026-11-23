import CHardware
import Darwin
import FanCore
import Foundation
import os

// launchd discards the daemon's stderr; the unified log keeps restoration failures visible:
// log show --predicate 'subsystem == "local.breeze.fancontrol.helper"' --last 1h
private let logger = Logger(subsystem: "local.breeze.fancontrol.helper", category: "helper")

func report(_ text: String) {
    logger.error("\(text, privacy: .public)")
    FileHandle.standardError.write(Data((text + "\n").utf8))
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
        // Never leave charging disabled after the session that requested it ends.
        for attempt in 0..<10 {
            do { try smc.restoreCharging(); break }
            catch {
                report("Re-enabling charging (attempt \(attempt+1)): \(error.localizedDescription)")
                usleep(200_000)
            }
        }
    }
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
        } catch {
            // A failed charging write disables the limiter rather than retrying a contested key.
            charger = nil
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
              charging: chargeStatus, chargingPaused: smc.chargingInhibited, power: power)
    }

    while true {
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
                        do { try smc.restoreCharging(); chargeStatus = nil }
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
        let data = try JSONEncoder().encode(SMC().snapshot())
        print(String(decoding: data, as: UTF8.self))
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
