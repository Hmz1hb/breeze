import CryptoKit
import Darwin
import Foundation
import CoreServices

public enum CleanupCategory: String, CaseIterable, Sendable {
    case developer = "Developer tools", projects = "Projects", appCaches = "App caches & logs"
    case models = "AI models", xcode = "Xcode & simulators", docker = "Docker"
    case applications = "Applications", leftovers = "App leftovers"
    case android = "Android emulators", downloads = "Downloaded installers", duplicates = "Duplicate files"

    public var symbol: String {
        switch self {
        case .developer: "hammer"
        case .projects: "folder.badge.gearshape"
        case .appCaches: "internaldrive"
        case .models: "cpu"
        case .xcode: "wrench.and.screwdriver"
        case .docker: "shippingbox"
        case .applications: "app.badge"
        case .leftovers: "tray"
        case .android: "smartphone"
        case .downloads: "shippingbox.and.arrow.backward"
        case .duplicates: "doc.on.doc"
        }
    }
}

public enum CleanupRisk: String, CaseIterable, Sendable {
    case rebuildable = "Rebuildable", review = "Check first", personal = "Your data"
}

public enum CleanupOpportunity: String, Codable, Sendable, CaseIterable {
    case duplicates = "Duplicate copies"
    case installers = "Downloaded installers"
    case virtualDevices = "Virtual devices"
    case runtimes = "Emulator system images"
    case rebuildable = "Rebuildable files"
    case downloadable = "Downloadable tools and models"
    case applications = "Apps not opened recently"
}

struct CleanupDuplicateEvidence: Sendable {
    let root: URL
    let keeper: StorageFile
    let copies: [StorageFile]
    let digest: String
}

public struct CleanupResource: Sendable {
    public let url: URL
    public let bytes: Int64
    public let modified: Date
    let stamp: FileStamp
    let fingerprint: String
    public var dates: CleanupResourceDates = .init()
    public var fileCount: Int = 0
    public var directoryCount: Int = 0
}

/// Root timestamps are separate from the newest modification anywhere in a tree.
/// Access time and Spotlight last use are evidence, never proof that data is unused.
public struct CleanupResourceDates: Sendable {
    public var created: Date?
    public var modified: Date?
    public var accessed: Date?
    public var lastOpened: Date?

    public init(created: Date? = nil, modified: Date? = nil, accessed: Date? = nil, lastOpened: Date? = nil) {
        self.created = created; self.modified = modified
        self.accessed = accessed; self.lastOpened = lastOpened
    }
}

public enum CleanupAction: Sendable {
    case trash
    case simulator(String)
    case simulatorRuntime(id: String, build: String)
    case dockerImage(context: String, endpoint: String, id: String)
    case dockerBuildCache(context: String, endpoint: String, builder: String, id: String)

    public var isPermanent: Bool {
        switch self { case .trash: false; default: true }
    }

    public var explanation: String {
        switch self {
        case .trash: "Move the listed files to Trash. Restore them with Finder if needed."
        case .simulator(let id): "Permanently delete simulator \(id) and its app data using xcrun simctl delete."
        case .simulatorRuntime(let id, _): "Permanently remove simulator runtime \(id) using xcrun simctl runtime delete. All simulators must be shut down."
        case .dockerImage(let context, _, let id): "Permanently remove Docker image \(id) in local context \(context), without forcing removal or pruning parents."
        case .dockerBuildCache(let context, _, let builder, let id): "Permanently prune only build cache record \(id) in local builder \(builder), context \(context)."
        }
    }
}

public struct CleanupContextSection: Sendable {
    public let title: String
    public let text: String
}

public struct CleanupContext: Sendable {
    public let summary: String
    public let sections: [CleanupContextSection]
}

public struct CleanupEntry: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: CleanupCategory
    public let risk: CleanupRisk
    public let detail: String
    public let recovery: String
    public let resources: [CleanupResource]
    public let action: CleanupAction
    public let estimatedBytes: Int64
    public let ownerID: String?
    public let ownerName: String?
    public let blockedReason: String?
    public let lastUsed: Date?
    public let processes: [String]
    // Ollama manifests are checked together before any model blobs move.
    let modelRegistry: CleanupResource?
    public let context: CleanupContext?
    public var ownerLastUsed: Date? = nil
    var duplicateEvidence: CleanupDuplicateEvidence? = nil

    public var bytes: Int64 { resources.isEmpty ? estimatedBytes : resources.reduce(0) { $0 + $1.bytes } }
    public var modified: Date? { resources.map(\.modified).max() }
    public var location: String { resources.first?.url.path ?? action.explanation }
    public var lastOpened: Date? { lastUsed ?? resources.compactMap(\.dates.lastOpened).max() }

    /// Candidates for a reasoned proposal, including choices with a recovery cost.
    /// This does not change the risk label or select anything for removal.
    public var opportunity: CleanupOpportunity? {
        guard bytes > 0 else { return nil }
        switch action {
        case .simulator: return .virtualDevices
        case .simulatorRuntime: return .runtimes
        case .dockerBuildCache: return .rebuildable
        default: break
        }
        switch category {
        case .duplicates: return .duplicates
        case .downloads: return .installers
        case .android: return resources.contains { $0.url.pathExtension == "avd" } ? .virtualDevices : .runtimes
        case .models: return .downloadable
        case .applications:
            if resources.contains(where: { $0.url.pathExtension == "app" }),
               let lastUsed, Date.now.timeIntervalSince(lastUsed) > 90 * 86_400 { return .applications }
        case .developer where risk == .review: return .downloadable
        default: break
        }
        return risk == .rebuildable && !action.isPermanent ? .rebuildable : nil
    }
}

public struct CleanupInventory: Sendable {
    public let entries: [CleanupEntry]
    public let issues: [String]
    public let finished: Date
    public let hasPermissionIssues: Bool
    public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    public init(entries: [CleanupEntry], issues: [String], finished: Date, hasPermissionIssues: Bool = false) {
        self.entries = entries
        self.issues = issues
        self.finished = finished
        self.hasPermissionIssues = hasPermissionIssues
    }

    public func removing(_ ids: Set<String>) -> Self {
        Self(entries: entries.filter { !ids.contains($0.id) }, issues: issues, finished: finished,
             hasPermissionIssues: hasPermissionIssues)
    }
}

/// A second, deliberately narrow scanner. The personal-file scanner keeps its
/// existing exclusions; this scanner only visits catalogued or explicitly chosen locations.
enum CleanupFiles {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    static func inside(_ url: URL, _ root: URL) -> Bool {
        url.path.hasPrefix(root.path + "/")
    }

    static func validateLocation(_ url: URL, application: Bool = false) throws {
        let canonical = url.standardizedFileURL
        let applications = URL(fileURLWithPath: "/Applications")
        let userApplications = home.appendingPathComponent("Applications")
        let allowedApp = application && url.pathExtension == "app" &&
            (inside(url, applications) || inside(url, userApplications)) &&
            !url.deletingLastPathComponent().pathComponents.contains(where: { $0.hasSuffix(".app") })
        guard url == canonical, inside(url, home) || allowedApp,
              !url.pathComponents.contains(".Trash"),
              !url.path.hasPrefix(home.appendingPathComponent("Library/Mobile Documents").path),
              !url.path.hasPrefix(home.appendingPathComponent("Library/CloudStorage").path) else {
            throw StorageError("Skipped by Breeze's cleanup rules: \(url.path). This location is outside the supported cleanup scope.")
        }
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw StorageError("Skipped linked path: \(url.path). Breeze does not clean through symbolic links.")
        }
        // resolvingSymlinksInPath can canonicalize /var; explicit ancestor checks
        // also reject an alias inserted between scanning and cleanup.
        var parent = url
        while parent.path != "/" {
            let (_, info) = try FileStamp.read(parent)
            guard info.st_mode & S_IFMT != S_IFLNK else {
                throw StorageError("Skipped linked path: \(parent.path). Breeze does not clean through symbolic links. Scan again if the path changed.")
            }
            parent.deleteLastPathComponent()
        }
    }

    static func snapshot(_ url: URL, application: Bool = false, limit: Int = 250_000, includeDates: Bool = true) throws -> CleanupResource {
        try validateLocation(url, application: application)
        let (initial, rootInfo) = try FileStamp.read(url)
        var hasher = SHA256()
        var bytes: Int64 = 0
        var modified = Date(timeIntervalSince1970: Double(initial.seconds))
        var visited = 0
        var fileCount = 0
        var directoryCount = 0
        // Capture before enumerating; do not interpret scan-related access as user activity.
        let metadata = includeDates ? MDItemCreate(kCFAllocatorDefault, url.path as CFString) : nil
        let lastOpened = metadata.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        let dates = CleanupResourceDates(
            created: rootInfo.st_birthtimespec.tv_sec > 0 ? Date(timeIntervalSince1970: Double(rootInfo.st_birthtimespec.tv_sec)) : nil,
            modified: Date(timeIntervalSince1970: Double(rootInfo.st_mtimespec.tv_sec)),
            accessed: rootInfo.st_atimespec.tv_sec > 0 ? Date(timeIntervalSince1970: Double(rootInfo.st_atimespec.tv_sec)) : nil,
            lastOpened: lastOpened)
        var identities: Set<String> = []
        let manager = FileManager()
        func visit(_ path: URL) throws {
            try Task.checkCancellation()
            visited += 1
            guard visited <= limit else { throw StorageError("Too many entries to measure completely: \(url.path)") }
            let (stamp, info) = try FileStamp.read(path)
            guard info.st_dev == rootInfo.st_dev, info.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw StorageError("A mounted volume or cloud-only file was skipped: \(path.path)")
            }
            let record = "\(path.path.dropFirst(url.path.count))\u{0}\(stamp.device):\(stamp.inode):\(stamp.size):\(stamp.seconds):\(stamp.nanoseconds):\(info.st_mode):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\u{0}"
            hasher.update(data: Data(record.utf8))
            modified = max(modified, Date(timeIntervalSince1970: Double(stamp.seconds)))
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                directoryCount += 1
                let children = try manager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                for child in children.sorted(by: { $0.path < $1.path }) { try visit(child) }
                guard try FileStamp.read(path).0 == stamp else { throw StorageError("Files changed during measurement: \(path.path)") }
            case S_IFREG, S_IFLNK:
                fileCount += 1
                // Interior links move with the directory but are never followed.
                if identities.insert("\(stamp.device):\(stamp.inode)").inserted {
                    bytes += max(0, Int64(info.st_blocks) * 512)
                }
            default:
                throw StorageError("Folder skipped because it contains a socket or special file: \(path.path). Quit the related app or service and rescan. If the file remains, the folder stays excluded.")
            }
        }
        try visit(url)
        guard try FileStamp.read(url).0 == initial else { throw StorageError("Files changed during measurement. Scan again.") }
        return CleanupResource(url: url, bytes: bytes, modified: modified, stamp: initial,
                               fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                               dates: dates, fileCount: fileCount, directoryCount: directoryCount)
    }

    static func validate(_ resource: CleanupResource, application: Bool = false) throws {
        let current = try snapshot(resource.url, application: application, includeDates: false)
        guard current.stamp == resource.stamp, current.fingerprint == resource.fingerprint else {
            throw StorageError("\(resource.url.lastPathComponent) changed since the scan. Scan again before removing it.")
        }
    }
}
