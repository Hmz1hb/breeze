import Darwin
import Foundation

struct CleanupCommandResult: Sendable {
    let status: Int32
    let data: Data
    let error: String
    var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

    func checked() throws -> Data {
        guard status == 0 else { throw StorageError(error.isEmpty ? "The cleanup tool exited with status \(status)." : String(error.prefix(800))) }
        return data
    }
}

/// Subprocesses are invoked directly with argument arrays, never a shell.
/// Private output files avoid pipe deadlocks; the lifecycle follows the app's
/// existing speed-test runner, with bounded output, cancellation and a timeout.
@MainActor final class CleanupCommand {
    private let process = Process()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("breeze-cleanup-\(UUID().uuidString)")
    private var output: FileHandle?
    private var errors: FileHandle?
    private var continuation: CheckedContinuation<CleanupCommandResult, any Error>?
    private var watchdog: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    private var failure: (any Error)?
    private let timeout: Double

    private init(executable: String, arguments: [String], timeout: Double) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // Keep CLI table labels and size units deterministic.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        self.timeout = timeout
    }

    static func run(_ executable: String, _ arguments: [String], timeout: Double = 25) async throws -> CleanupCommandResult {
        let operation = CleanupCommand(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.start()
        } onCancel: {
            Task { @MainActor in operation.stop(CancellationError()) }
        }
    }

    private func start() async throws -> CleanupCommandResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let stdout = directory.appendingPathComponent("stdout")
            let stderr = directory.appendingPathComponent("stderr")
            guard FileManager.default.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  FileManager.default.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StorageError("Cannot prepare cleanup tool output.")
            }
            output = try FileHandle(forWritingTo: stdout)
            errors = try FileHandle(forWritingTo: stderr)
            process.standardOutput = output
            process.standardError = errors
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                process.terminationHandler = { [self] _ in Task { @MainActor in finish() } }
                do {
                    try Task.checkCancellation()
                    try process.run()
                    watchdog = Task {
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        stop(StorageError("The cleanup tool timed out. Scan again to check its result before retrying."))
                    }
                } catch { finish(error) }
            }
        } catch {
            try? output?.close(); try? errors?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func stop(_ error: any Error) {
        failure = error
        guard process.isRunning else { return }
        process.terminate()
        fallback = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func finish(_ error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel(); fallback?.cancel()
        process.terminationHandler = nil
        try? output?.close(); try? errors?.close()
        defer { try? FileManager.default.removeItem(at: directory) }
        if let error = error ?? failure { continuation.resume(throwing: error); return }
        do {
            let stdout = try FileHandle(forReadingFrom: directory.appendingPathComponent("stdout"))
            let stderr = try FileHandle(forReadingFrom: directory.appendingPathComponent("stderr"))
            defer { try? stdout.close(); try? stderr.close() }
            let data = try stdout.read(upToCount: 8_388_609) ?? Data()
            guard data.count <= 8_388_608 else { throw StorageError("Cleanup tool output exceeded its limit. Use the tool directly for this inventory.") }
            let errorData = try stderr.read(upToCount: 8_192) ?? Data()
            continuation.resume(returning: CleanupCommandResult(status: process.terminationStatus, data: data,
                error: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch { continuation.resume(throwing: error) }
    }
}
