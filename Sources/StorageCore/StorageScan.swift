import CryptoKit
import Darwin
import Foundation

public struct StorageError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct FileStamp: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    static func read(_ url: URL) throws -> (FileStamp, stat) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: "Cannot read \(url.path): \(String(cString: strerror(code)))."
            ])
        }
        return (FileStamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                          seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec), info)
    }
}

public enum FileCategory: String, CaseIterable, Sendable {
    case video = "Video", images = "Images", audio = "Audio", documents = "Documents", archives = "Archives", other = "Other"
    public static func category(for url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "mkv", "avi", "m4v", "webm": .video
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "raw", "webp", "svg": .images
        case "mp3", "wav", "m4a", "aiff", "flac", "aac": .audio
        case "pdf", "doc", "docx", "txt", "md", "pages", "xlsx", "csv", "pptx", "key": .documents
        case "zip", "gz", "tar", "7z", "rar", "dmg", "pkg", "iso": .archives
        default: .other
        }
    }
}

public struct StorageFile: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public let allocatedBytes: Int64
    public let modified: Date
    public let category: FileCategory
    public let stamp: FileStamp

    public func suggestion(now: Date = .now) -> String? {
        let days = now.timeIntervalSince(modified) / 86_400
        if ["dmg", "pkg", "iso"].contains(url.pathExtension.lowercased()), days >= 30 {
            return "Installer or disk image · unchanged for 30+ days"
        }
        if bytes >= 100_000_000, days >= 180 { return "Large file · unchanged for 6+ months" }
        if bytes >= 1_000_000_000 { return "Large file · over 1 GB" }
        return nil
    }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let files: [StorageFile]
    public var extraBytes: Int64 { Int64(max(0, files.count - 1)) * (files.first?.bytes ?? 0) }
}

public struct ScanProgress: Sendable {
    public let phase: String
    public let files: Int
}

public struct StorageScan: Sendable {
    public let root: URL
    public let files: [StorageFile]
    public let duplicates: [DuplicateGroup]
    public let skipped: Int
    public let unreadable: Int
    public let duplicateReadFailures: Int
    public let reachedLimit: Bool
    public let finished: Date
    public let duplicatesComplete: Bool
    public let bytes: Int64
    public let allocatedBytes: Int64
    public let extraDuplicateBytes: Int64
    public let directoryIndex: [String: [StorageNode]]

    init(root: URL, files: [StorageFile], duplicates: [DuplicateGroup], skipped: Int,
         unreadable: Int, duplicateReadFailures: Int, reachedLimit: Bool, finished: Date,
         duplicatesComplete: Bool = true, directoryIndex: [String: [StorageNode]]? = nil) {
        self.root = root; self.files = files; self.duplicates = duplicates
        self.skipped = skipped; self.unreadable = unreadable
        self.duplicateReadFailures = duplicateReadFailures; self.reachedLimit = reachedLimit
        self.finished = finished; self.duplicatesComplete = duplicatesComplete
        bytes = files.reduce(0) { $0 + $1.bytes }
        allocatedBytes = files.reduce(0) { $0 + $1.allocatedBytes }
        extraDuplicateBytes = duplicates.reduce(0) { $0 + $1.extraBytes }
        self.directoryIndex = directoryIndex ?? StorageNode.directoryIndex(root: root, files: files)
    }

    /// Remove only confirmed Trash moves, keeping the rest of this scan available for browsing.
    public func removingFiles(_ removed: Set<String>) -> StorageScan {
        let remainingGroups = duplicates.compactMap { group -> DuplicateGroup? in
            let remaining = group.files.filter { !removed.contains($0.id) }
            return remaining.count > 1 ? DuplicateGroup(id: group.id, files: remaining) : nil
        }
        return StorageScan(root: root, files: files.filter { !removed.contains($0.id) },
                           duplicates: remainingGroups.sorted { $0.extraBytes > $1.extraBytes },
                           skipped: skipped, unreadable: unreadable, duplicateReadFailures: duplicateReadFailures,
                           reachedLimit: reachedLimit, finished: finished, duplicatesComplete: duplicatesComplete)
    }
}

public enum StorageScanner {
    /// Never scan OS data, application bundles, hidden data or application libraries.
    public static func allowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let blocked = ["/System", "/Library", "/private", "/dev", "/bin", "/sbin", "/usr", "/Volumes"]
        if blocked.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        return !url.pathComponents.contains(where: {
            $0 == "Library" || $0.hasPrefix(".") || ["app", "photoslibrary", "photolibrary", "bundle", "framework"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        })
    }

    @concurrent public static func scan(
        root requestedRoot: URL, limit: Int = 250_000,
        includingInstallerFiles: Bool = false,
        inventory: @escaping @Sendable (StorageScan) async -> Void = { _ in },
        progress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }
    ) async throws -> StorageScan {
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard allowed(root), limit > 0 else { throw StorageError("Choose a personal folder, such as Downloads or Documents. System data, libraries and app bundles are excluded.") }
        let manager = FileManager()
        let rootDevice = try FileStamp.read(root).0.device
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isReadableKey])
        guard rootValues.isDirectory == true, rootValues.isPackage != true, rootValues.isReadable == true else {
            throw StorageError("This folder cannot be scanned. Choose a readable folder.")
        }
        var unreadable = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isUbiquitousItemKey]
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                  errorHandler: { _, _ in unreadable += 1; return true }) else {
            throw StorageError("Cannot list this folder.")
        }
        var files: [StorageFile] = []
        var identities: Set<String> = []
        var skipped = 0
        var reachedLimit = false
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            if visited % 256 == 0 { await progress(ScanProgress(phase: "Reading folders", files: files.count)) }
            do {
                let values = try url.resourceValues(forKeys: keys)
                let installerFile = includingInstallerFiles && values.isRegularFile == true &&
                    ["dmg", "pkg", "iso"].contains(url.pathExtension.lowercased())
                guard allowed(url), values.isSymbolicLink != true, (values.isPackage != true || installerFile),
                      values.isUbiquitousItem != true else {
                    enumerator.skipDescendants(); skipped += 1; continue
                }
                let (stamp, info) = try FileStamp.read(url)
                if info.st_dev != rootDevice {
                    enumerator.skipDescendants(); skipped += 1; continue
                }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true, info.st_mode & S_IFMT == S_IFREG,
                      info.st_flags & UInt32(SF_DATALESS) == 0 else { skipped += 1; continue }
                let identity = "\(stamp.device):\(stamp.inode)"
                guard identities.insert(identity).inserted else { skipped += 1; continue }
                files.append(StorageFile(url: url, bytes: max(0, stamp.size), allocatedBytes: max(0, Int64(info.st_blocks) * 512),
                                         modified: Date(timeIntervalSince1970: Double(stamp.seconds)),
                                         category: FileCategory.category(for: url), stamp: stamp))
                if files.count >= limit { reachedLimit = true; break }
            } catch { unreadable += 1 }
        }
        files.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        let directoryIndex = StorageNode.directoryIndex(root: root, files: files)
        try Task.checkCancellation()
        await inventory(StorageScan(root: root, files: files, duplicates: [], skipped: skipped,
                                    unreadable: unreadable, duplicateReadFailures: 0, reachedLimit: reachedLimit,
                                    finished: .now, duplicatesComplete: false, directoryIndex: directoryIndex))
        await progress(ScanProgress(phase: "Checking duplicate contents", files: files.count))
        var duplicateFailures = 0
        var duplicates: [DuplicateGroup] = []
        let bySize = Dictionary(grouping: files.filter { $0.bytes > 0 }, by: \.bytes)
        var checked = 0
        for candidates in bySize.values where candidates.count > 1 {
            try Task.checkCancellation()
            // A prefix pass avoids reading large, unrelated files in full.
            var prefixes: [String: [StorageFile]] = [:]
            for file in candidates {
                do { prefixes[try digest(file, prefixOnly: true), default: []].append(file) }
                catch is CancellationError { throw CancellationError() }
                catch { duplicateFailures += 1 }
            }
            for matches in prefixes.values where matches.count > 1 {
                var hashes: [String: [StorageFile]] = [:]
                for file in matches {
                    do { hashes[try digest(file), default: []].append(file) }
                    catch is CancellationError { throw CancellationError() }
                    catch { duplicateFailures += 1 }
                    checked += 1
                    if checked % 16 == 0 { await progress(ScanProgress(phase: "Checking duplicate contents", files: files.count)) }
                }
                for (hash, identical) in hashes where identical.count > 1 {
                    duplicates.append(DuplicateGroup(id: hash, files: identical.sorted { $0.id < $1.id }))
                }
            }
        }
        try Task.checkCancellation()
        return StorageScan(root: root, files: files,
                           duplicates: duplicates.sorted { $0.extraBytes > $1.extraBytes }, skipped: skipped,
                           unreadable: unreadable, duplicateReadFailures: duplicateFailures,
                           reachedLimit: reachedLimit, finished: .now, directoryIndex: directoryIndex)
    }

    static func validate(_ file: StorageFile, root: URL) throws {
        guard file.url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/"), allowed(file.url),
              file.url.resolvingSymlinksInPath().path == file.url.path else {
            throw StorageError("The location of \(file.url.lastPathComponent) changed. Scan again.")
        }
        let (stamp, info) = try FileStamp.read(file.url)
        guard stamp == file.stamp, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw StorageError("\(file.url.lastPathComponent) changed since the scan. Scan again.")
        }
    }

    static func digest(_ file: StorageFile, prefixOnly: Bool = false) throws -> String {
        try Task.checkCancellation()
        let (before, _) = try FileStamp.read(file.url)
        guard before == file.stamp, file.url.resolvingSymlinksInPath().path == file.url.path else {
            throw StorageError("File changed while checking duplicates.")
        }
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw StorageError("Cannot read file contents.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_ino == before.inode, opened.st_dev == before.device else { throw StorageError("File changed.") }
        var hasher = SHA256()
        repeat {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: prefixOnly ? 65_536 : 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            if prefixOnly { break }
        } while true
        guard try FileStamp.read(file.url).0 == before else { throw StorageError("File changed during reading.") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
