import Darwin
import Foundation
import StorageCore

enum CleanupAssistantClient: String, CaseIterable {
    case codex, claude

    var name: String { self == .codex ? "Codex" : "Claude Code" }

    /// Finder-launched apps do not inherit the user's interactive shell PATH.
    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nodeRoot = URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node")
        let nodeBins = ((try? FileManager.default.contentsOfDirectory(at: nodeRoot, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin").path }
        return ["\(home)/.local/bin", "\(home)/.volta/bin", "\(home)/.npm-global/bin",
                "/opt/homebrew/bin", "/usr/local/bin"] + nodeBins
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    var executable: URL? {
        let bundled = self == .codex ? [URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")] : []
        return (Self.searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(rawValue) } + bundled)
            .lazy
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func detected(preferred: String?) -> Self? {
        if let preferred, let client = Self(rawValue: preferred), client.executable != nil { return client }
        return allCases.first { $0.executable != nil }
    }

    func arguments(server: URL, snapshotID: String) throws -> [String] {
        let toolNames = ["cleanup_summary", "list_items", "inspect_items", "propose_cleanup"]
        switch self {
        case .codex:
            // JSON string quoting is also valid for these TOML basic string values.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let quotedPath = String(decoding: try encoder.encode(server.path), as: UTF8.self)
            let quotedSnapshot = String(decoding: try encoder.encode(snapshotID), as: UTF8.self)
            return ["exec", "--ignore-user-config", "--skip-git-repo-check", "--sandbox", "read-only",
                    "-c", "approval_policy=\"never\"", "-c", "features.shell_tool=false",
                    "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                    "-c", "mcp_servers.breeze.command=\(quotedPath)",
                    "-c", "mcp_servers.breeze.env.BREEZE_ASSISTANT_SNAPSHOT_ID=\(quotedSnapshot)",
                    "-c", "mcp_servers.breeze.required=true",
                    "-c", "mcp_servers.breeze.default_tools_approval_mode=\"auto\"", "-"]
        case .claude:
            let configuration = try JSONSerialization.data(withJSONObject: [
                "mcpServers": ["breeze": ["command": server.path, "args": [] as [String],
                    "env": ["BREEZE_ASSISTANT_SNAPSHOT_ID": snapshotID]]]
            ], options: [.sortedKeys])
            return ["-p", "--output-format", "text", "--tools", "", "--setting-sources", "",
                    "--settings", "{\"disableAllHooks\":true}", "--strict-mcp-config",
                    "--mcp-config", String(decoding: configuration, as: UTF8.self),
                    "--allowedTools", toolNames.map { "mcp__breeze__\($0)" }.joined(separator: ",")]
        }
    }
}

/// A one-shot CLI session. No shell, global MCP registration, or credential reads.
/// Private files keep prompts out of process arguments and avoid blocked pipes.
@MainActor final class CleanupAssistantRunner {
    private let process = Process()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("breeze-assistant-\(UUID().uuidString)")
    private var handles: [FileHandle] = []
    private var continuation: CheckedContinuation<String, any Error>?
    private var watchdog: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    private var failure: (any Error)?

    static func run(client: CleanupAssistantClient, executable: URL, server: URL, snapshotID: String, prompt: String) async throws -> String {
        let runner = CleanupAssistantRunner()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await runner.start(client: client, executable: executable, server: server, snapshotID: snapshotID, prompt: prompt)
        } onCancel: {
            Task { @MainActor in runner.stop(CancellationError()) }
        }
    }

    private func start(client: CleanupAssistantClient, executable: URL, server: URL, snapshotID: String, prompt: String) async throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for name in ["prompt", "stdout", "stderr"] {
                guard FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path,
                    contents: name == "prompt" ? Data(prompt.utf8) : nil, attributes: [.posixPermissions: 0o600]) else {
                    throw StorageError("Could not prepare the assistant session.")
                }
            }
            let input = try FileHandle(forReadingFrom: directory.appendingPathComponent("prompt"))
            handles.append(input)
            let output = try FileHandle(forWritingTo: directory.appendingPathComponent("stdout"))
            handles.append(output)
            let errors = try FileHandle(forWritingTo: directory.appendingPathComponent("stderr"))
            handles.append(errors)
            process.executableURL = executable
            process.arguments = try client.arguments(server: server, snapshotID: snapshotID)
            process.currentDirectoryURL = directory
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ([executable.deletingLastPathComponent().path] + CleanupAssistantClient.searchDirectories).joined(separator: ":")
            // Let the official CLI use its own login; never fall back to inherited API keys.
            for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE"] {
                environment.removeValue(forKey: key)
            }
            process.environment = environment
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                process.terminationHandler = { [self] _ in Task { @MainActor in finish() } }
                do {
                    try Task.checkCancellation()
                    try process.run()
                    watchdog = Task {
                        for _ in 0..<300 {
                            do { try await Task.sleep(for: .seconds(2)) } catch { return }
                            if outputSizeExceeded() {
                                stop(StorageError("Assistant output exceeded its limit. Try a more focused request."))
                                return
                            }
                        }
                        stop(StorageError("The assistant timed out after ten minutes. Check your CLI login and try again."))
                    }
                } catch { finish(error) }
            }
        } catch {
            closeFiles()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func outputSizeExceeded() -> Bool {
        ["stdout", "stderr"].contains { name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 2 * 1024 * 1024
        }
    }

    private func stop(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        guard process.isRunning else { return }
        process.terminate()
        fallback = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func closeFiles() {
        for handle in handles { try? handle.close() }
        handles = []
    }

    private func read(_ name: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 2 * 1024 * 1024 else { throw StorageError("Assistant output exceeded its limit.") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finish(_ error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel(); fallback?.cancel()
        process.terminationHandler = nil
        closeFiles()
        defer { try? FileManager.default.removeItem(at: directory) }
        if let error = error ?? failure { continuation.resume(throwing: error); return }
        do {
            let output = try read("stdout")
            guard process.terminationStatus == 0 else {
                let errors = try read("stderr")
                let detail = errors.isEmpty ? output : errors
                throw StorageError("Assistant exited with status \(process.terminationStatus). \(String(detail.suffix(1500)))\nCheck that the CLI is up to date and signed in from Terminal, then try again.")
            }
            continuation.resume(returning: String(output.prefix(6000)))
        } catch { continuation.resume(throwing: error) }
    }
}
