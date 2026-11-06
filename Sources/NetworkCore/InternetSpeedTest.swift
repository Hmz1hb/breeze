import Foundation

public struct InternetSpeedResult: Sendable, Equatable {
    public let downloadMbps: Double
    public let uploadMbps: Double
    public let idleLatency: Double?
    public let responsiveness: Double?
    public let date: Date

    /// networkQuality reports throughput in bits/s and idle latency in ms.
    public static func parse(_ data: Data, date: Date = .now) throws -> Self {
        let report = try JSONDecoder().decode(Report.self, from: data)
        guard report.error == nil, let down = report.dl_throughput, let up = report.ul_throughput,
              down.isFinite, down > 0, up.isFinite, up > 0 else { throw InternetSpeedError.noResult }
        return Self(downloadMbps: down / 1_000_000, uploadMbps: up / 1_000_000,
                    idleLatency: report.base_rtt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                    responsiveness: report.responsiveness.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, date: date)
    }
    private struct Report: Decodable {
        let dl_throughput: Double?
        let ul_throughput: Double?
        let base_rtt: Double?
        let responsiveness: Double?
        // Error payloads vary between macOS releases; their presence invalidates a run.
        let error: ErrorPayload?
        struct ErrorPayload: Decodable {
            init(from decoder: any Decoder) throws {}
        }
    }
}

public enum InternetSpeedError: LocalizedError {
    case unavailable, noResult, timedOut
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The macOS speed test could not start. Try again."
        case .noResult: "The speed test could not measure this connection. Check internet access, VPN or firewall settings and try again."
        case .timedOut: "The speed test timed out. Check your internet connection and try again."
        }
    }
}

public enum InternetSpeedTest {
    @MainActor public static func run(interface: String) async throws -> InternetSpeedResult {
        let operation = SpeedTestOperation(interface: interface)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await operation.run()
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { @MainActor in operation.cancel() }
        }
    }
}

/// Process lifecycle stays on the main actor; the subprocess performs the work.
/// A private output file avoids blocking a pipe or buffering test traffic in Breeze.
@MainActor private final class SpeedTestOperation {
    private let process = Process()
    private let output = FileManager.default.temporaryDirectory.appendingPathComponent("breeze-speed-\(UUID().uuidString).json")
    private var continuation: CheckedContinuation<InternetSpeedResult, any Error>?
    private var watchdog: Task<Void, Never>?
    private var terminationFallback: Task<Void, Never>?
    private var failure: (any Error)?

    init(interface: String) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        // networkQuality's optional -c argument must be attached to the flag.
        process.arguments = ["-c\(output.path)", "-M", "30", "-I", interface]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func run() async throws -> InternetSpeedResult {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            process.terminationHandler = { [self] _ in Task { @MainActor in finish() } }
            do {
                try process.run()
                watchdog = Task {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    stop(with: InternetSpeedError.timedOut)
                }
            } catch { finish(error: InternetSpeedError.unavailable) }
        }
    }

    func cancel() { stop(with: CancellationError()) }

    private func stop(with error: any Error) {
        failure = error
        guard process.isRunning else { return }
        process.terminate()
        terminationFallback = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func finish(error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel(); terminationFallback?.cancel()
        process.terminationHandler = nil
        defer { try? FileManager.default.removeItem(at: output) }
        if let error = error ?? failure { continuation.resume(throwing: error); return }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: output), data.count < 1_048_576,
              let result = try? InternetSpeedResult.parse(data) else {
            continuation.resume(throwing: InternetSpeedError.noResult); return
        }
        continuation.resume(returning: result)
    }
}
