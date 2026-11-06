import AppKit
import Darwin
import Foundation

public struct CleanupProcessBlocker: Identifiable, Sendable {
    public let id: Int32
    public let name: String
    public let command: String
    public let canStop: Bool
    public let affectedEntryIDs: Set<String>
    let identity: String
    let bundleID: String?
}

public struct CleanupProcessesRunning: LocalizedError, Sendable {
    public let blockers: [CleanupProcessBlocker]
    public var errorDescription: String? {
        "Running processes need your attention. Review them in Breeze, then stop and rescan before cleanup."
    }
}

/// Resolve exact user-owned PIDs for review. Never stop a process by name or
/// force quit an app; the user approves individual processes in Breeze.
public enum CleanupProcesses {
    private struct Snapshot {
        let identity: String
        let parent: Int32
        let user: UInt32
    }

    private static func snapshot(_ pid: Int32) async throws -> Snapshot? {
        let result = try await CleanupCommand.run("/bin/ps",
            ["-p", String(pid), "-o", "uid=", "-o", "ppid=", "-o", "lstart=", "-o", "comm="], timeout: 5)
        if result.status == 1, result.text.isEmpty { return nil }
        guard result.status == 0 else { throw StorageError("Could not verify process \(pid). Try refreshing the running processes.") }
        let fields = result.text.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 8, let user = UInt32(fields[0]), let parent = Int32(fields[1]) else {
            throw StorageError("Could not identify process \(pid). No stop request was sent.")
        }
        return Snapshot(identity: result.text, parent: parent, user: user)
    }

    private static func protectedProcesses() async throws -> Set<Int32> {
        var protected: Set<Int32> = [1, getpid()]
        var parent = getppid()
        // Protect Breeze and its launching terminal/agent as well as PID 1.
        for _ in 0..<64 {
            guard parent > 1, protected.insert(parent).inserted,
                  let info = try await snapshot(parent) else { break }
            parent = info.parent
        }
        return protected
    }

    @MainActor private static func applications(for entries: [CleanupEntry]) -> [(Int32, String, String, Set<String>)] {
        var owners = Set(entries.compactMap(\.ownerID))
        if entries.contains(where: { $0.category == .xcode }) {
            owners.formUnion(["com.apple.dt.Xcode", "com.apple.iphonesimulator"])
        }
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let owner = app.bundleIdentifier, owners.contains(owner) else { return nil }
            let affected = Set(entries.filter {
                $0.ownerID == owner || ($0.category == .xcode && ["com.apple.dt.Xcode", "com.apple.iphonesimulator"].contains(owner))
            }.map(\.id))
            return (app.processIdentifier, app.localizedName ?? owner, owner, affected)
        }
    }

    @concurrent public static func blockers(for entries: [CleanupEntry]) async throws -> [CleanupProcessBlocker] {
        var candidates: [Int32: (name: String, bundleID: String?, entries: Set<String>)] = [:]
        for name in Set(entries.flatMap(\.processes)).sorted() {
            try Task.checkCancellation()
            let result = try await CleanupCommand.run("/usr/bin/pgrep", ["-u", String(getuid()), "-x", name], timeout: 5)
            guard result.status == 0 || result.status == 1 else {
                throw StorageError("Could not check whether \(name) is running. Refresh before cleanup.")
            }
            for line in result.text.split(whereSeparator: \.isNewline) {
                guard let pid = Int32(line), pid > 1 else { continue }
                let affected = Set(entries.filter { $0.processes.contains(name) }.map(\.id))
                candidates[pid] = (name, nil, (candidates[pid]?.entries ?? []).union(affected))
            }
        }
        for (pid, name, owner, affected) in await applications(for: entries) {
            candidates[pid] = (name, owner, (candidates[pid]?.entries ?? []).union(affected))
        }
        guard !candidates.isEmpty else { return [] }
        let protected = try await protectedProcesses()
        var blockers: [CleanupProcessBlocker] = []
        for pid in candidates.keys.sorted() {
            try Task.checkCancellation()
            guard let candidate = candidates[pid], let info = try await snapshot(pid) else { continue }
            let command = try await CleanupCommand.run("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 5)
            if command.status == 1, command.text.isEmpty { continue } // Exited while inspecting.
            guard command.status == 0 else { throw StorageError("Could not inspect process \(pid). Refresh before cleanup.") }
            blockers.append(CleanupProcessBlocker(id: pid, name: candidate.name,
                command: String(command.text.prefix(1200)), canStop: info.user == getuid() && !protected.contains(pid),
                affectedEntryIDs: candidate.entries,
                identity: info.identity, bundleID: candidate.bundleID))
        }
        return blockers
    }

    @MainActor private static func quitApplication(_ blocker: CleanupProcessBlocker) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: blocker.id),
              app.bundleIdentifier == blocker.bundleID else { return false }
        return app.terminate()
    }

    @concurrent public static func stop(_ blockers: [CleanupProcessBlocker]) async throws -> [String] {
        let protected = try await protectedProcesses()
        // Validate the entire approval before sending any stop requests. The
        // timestamp, executable, UID and parent must still match the reviewed PID.
        var current: [CleanupProcessBlocker] = []
        for blocker in blockers {
            try Task.checkCancellation()
            guard blocker.canStop, !protected.contains(blocker.id) else {
                throw StorageError("\(blocker.name) is protected because it runs Breeze or its launching session.")
            }
            guard let info = try await snapshot(blocker.id) else { continue }
            guard info.user == getuid(), info.identity == blocker.identity else {
                throw StorageError("Process \(blocker.id) changed since review. Refresh the process list before stopping it.")
            }
            current.append(blocker)
        }
        var failures: [String] = []
        for blocker in current {
            try Task.checkCancellation()
            guard let info = try await snapshot(blocker.id) else { continue }
            guard info.user == getuid(), info.identity == blocker.identity else {
                failures.append("\(blocker.name) (PID \(blocker.id)) changed and was left running."); continue
            }
            if blocker.bundleID != nil {
                if !(await quitApplication(blocker)) { failures.append("Could not ask \(blocker.name) to quit. Quit it from its app menu.") }
            } else if kill(blocker.id, SIGTERM) != 0, errno != ESRCH {
                failures.append("Could not stop \(blocker.name) (PID \(blocker.id)).")
            }
        }
        // Apps can show a Save dialog or decline to quit. Give them time without
        // blocking the main thread, then leave remaining processes alone.
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var remaining = current
        while !remaining.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            var running: [CleanupProcessBlocker] = []
            for blocker in remaining {
                if let info = try await snapshot(blocker.id), info.identity == blocker.identity { running.append(blocker) }
            }
            remaining = running
        }
        for blocker in remaining {
            failures.append("\(blocker.name) (PID \(blocker.id)) is still running. Check for a Save dialog or stop it in Activity Monitor.")
        }
        return failures
    }
}
