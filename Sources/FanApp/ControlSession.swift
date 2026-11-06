import CHardware
import Darwin
import FanCore
import Foundation

protocol CoolingSession: Sendable {
    func enable() async throws -> Reply
    func request(_ command: Command) async throws -> Reply
    func stop() async
}

actor ControlSession: CoolingSession {
    private var fd: Int32 = -1
    private var generation = UUID()

    func enable() async throws -> Reply {
        if fd >= 0 { return try request(Command(.heartbeat)) }
        let attempt = UUID()
        generation = attempt
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard generation == attempt else { throw FanError("Control session cancelled.") }
                let connected = breeze_connect(HelperIdentity.socket)
                if connected >= 0 {
                    var uid: uid_t = 0, pid: pid_t = 0
                    // launchd creates this socket in root-owned /var/run. Its peer can
                    // be launchd itself (PID 1), rather than the activated helper.
                    guard breeze_peer(connected, &uid, &pid) == 0, uid == 0 else {
                        close(connected)
                        throw FanError("The cooling helper has an unexpected identity.")
                    }
                    fd = connected
                    guard let reply = try Wire.receive(Reply.self, from: fd, timeout: 5000) else {
                        throw FanError("The cooling helper did not become ready. Another Breeze window may already be connected.")
                    }
                    guard reply.ok else { throw FanError(reply.message) }
                    return reply
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw FanError("Cannot reach the cooling helper. Check Breeze in System Settings → General → Login Items & Extensions.")
        } catch { cleanup(); throw error }
    }

    func request(_ command: Command) throws -> Reply {
        guard fd >= 0 else { throw FanError("Enable fan control first.") }
        do {
            try Wire.send(command, to: fd)
            guard let reply = try Wire.receive(Reply.self, from: fd, timeout: [.manual, .configure, .wake].contains(command.action) ? 15000 : 5500) else {
                throw FanError("The helper stopped responding. Its watchdog will attempt to restore automatic control.")
            }
            return reply
        } catch { cleanup(); throw error }
    }
    func stop() {
        if fd >= 0 { _ = try? request(Command(.quit)) }
        cleanup()
    }
    private func cleanup() {
        generation = UUID()
        if fd >= 0 { close(fd); fd = -1 }
        // Closing the socket restores automatic control; the registered helper
        // remains available for the next app session without new authorization.
    }
}

actor Monitor {
    private var smc: SMC?
    private var stats = SystemStatsReader()
    struct Reading: Sendable { let snapshot: Snapshot; let stats: SystemStats? }
    func read() throws -> Reading {
        if smc == nil { smc = try SMC() }
        do { return Reading(snapshot: try smc!.snapshot(), stats: try? stats.read()) }
        catch { smc = nil; throw error }
    }
}
