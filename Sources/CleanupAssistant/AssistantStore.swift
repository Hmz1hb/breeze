import Darwin
import Foundation
import StorageCore

/// This private, fixed directory is the entire bridge. It contains metadata and
/// proposals, never cleanup authority or the assistants' credentials.
public struct AssistantStore: Sendable {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Breeze/CleanupAssistant", isDirectory: true)
    }

    public init() {}

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func publish(_ snapshot: AssistantSnapshot) throws {
        try snapshot.requireCurrent()
        try prepareDirectory()
        try remove("proposal.json")
        try write(Self.encoder().encode(snapshot), name: "snapshot.json")
    }

    public func snapshot() throws -> AssistantSnapshot {
        let snapshot: AssistantSnapshot = try read("snapshot.json", limit: 24 * 1024 * 1024)
        try snapshot.requireCurrent()
        return snapshot
    }

    public func propose(_ proposal: AssistantProposal) throws {
        let current = try snapshot()
        try proposal.validate(against: current)
        try write(Self.encoder().encode(proposal), name: "proposal.json")
        // Revocation or replacement during the write must not yield a valid proposal.
        guard try snapshot().id == current.id else {
            throw StorageError("The shared scan changed. Read the new summary before proposing again.")
        }
    }

    public func proposal() throws -> AssistantProposal? {
        guard FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("proposal.json").path) else { return nil }
        return try read("proposal.json", limit: 1024 * 1024)
    }

    public func dismissProposal() throws { try remove("proposal.json") }

    public func revoke() throws {
        // Revoke reads first, even if removing a pending proposal fails.
        try remove("snapshot.json")
        try remove("proposal.json")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try checkDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.directory.path)
    }

    private func checkDirectory() throws {
        let path = Self.directory
        guard path.resolvingSymlinksInPath().standardizedFileURL == path.standardizedFileURL else {
            throw StorageError("AI sharing cannot use a linked directory.")
        }
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            throw StorageError("No shared cleanup scan is available. Open Breeze → Cleanup & apps → AI assistant and enable sharing.")
        }
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw StorageError("AI sharing needs a private folder owned by your macOS account.")
        }
    }

    private func read<Value: Decodable>(_ name: String, limit: Int) throws -> Value {
        try checkDirectory()
        let url = Self.directory.appendingPathComponent(name)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StorageError("No shared cleanup scan is available. Open Breeze → Cleanup & apps → AI assistant and enable sharing.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= Int64(limit) else {
            throw StorageError("The AI sharing file is not a private, supported metadata file.")
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw StorageError("AI sharing metadata is too large.") }
        }
        return try Self.decoder().decode(Value.self, from: data)
    }

    private func write(_ data: Data, name: String) throws {
        try checkDirectory()
        guard data.count <= 24 * 1024 * 1024 else { throw StorageError("This cleanup inventory is too large to share with AI.") }
        let temporary = Self.directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let destination = Self.directory.appendingPathComponent(name)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageError("Could not create private AI sharing metadata.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else {
            throw StorageError("Could not publish AI sharing metadata.")
        }
    }

    private func remove(_ name: String) throws {
        var directoryInfo = stat()
        if lstat(Self.directory.path, &directoryInfo) != 0, errno == ENOENT { return }
        try checkDirectory()
        let path = Self.directory.appendingPathComponent(name).path
        // unlink removes only this directory entry, and never follows a final symlink.
        guard unlink(path) == 0 || errno == ENOENT else {
            throw StorageError("Could not remove AI sharing metadata. Check permissions for \(Self.directory.path).")
        }
    }
}
