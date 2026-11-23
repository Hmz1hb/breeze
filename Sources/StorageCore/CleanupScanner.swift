import AppKit
import CoreServices
import Foundation

struct CleanupApp: Sendable {
    let id: String
    let name: String
    let url: URL
    let lastUsed: Date?
}

enum CleanupRunningApps {
    @MainActor static func identifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

public enum CleanupScanner {
    public static var defaultProjectRoots: [URL] {
        ["Developer", "Projects", "Code", "Desktop/projects"].map { CleanupFiles.home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @concurrent public static func scan(
        projectRoots: [URL], progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> CleanupInventory {
        let running = await CleanupRunningApps.identifiers()
        await progress("Reading Xcode device and project names")
        let xcode = try CleanupXcodeMetadata()
        let builder = CleanupInventoryBuilder(running: running, xcode: xcode)
        await progress("Finding installed applications")
        try builder.findApplications()
        for rule in CleanupCatalog.rules {
            try Task.checkCancellation()
            await progress("Checking \(rule.title)")
            builder.add(rule)
        }
        await progress("Checking Android virtual devices and system images")
        try builder.findAndroid()
        await progress("Checking Downloads installers and duplicate contents")
        try await builder.findDownloads(progress: progress)
        await progress("Checking app caches, logs and related files")
        try builder.findAppData()
        for root in projectRoots {
            try Task.checkCancellation()
            await progress("Looking for projects in \(root.lastPathComponent)")
            try builder.findProjects(root)
        }
        await progress("Checking local AI models")
        try builder.findModels()
        await progress("Checking Xcode simulators")
        let simulators = try await CleanupTools.simulators(metadata: xcode)
        builder.entries += simulators.entries
        builder.issues += simulators.issues
        await progress("Checking local Docker images and build cache")
        let docker = try await CleanupTools.docker()
        builder.entries += docker.entries
        builder.issues += docker.issues
        try Task.checkCancellation()
        return CleanupInventory(entries: builder.entries.sorted {
            $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
        }, issues: builder.issues, finished: .now, hasPermissionIssues: builder.hasPermissionIssues)
    }
}

final class CleanupInventoryBuilder {
    let running: Set<String>
    let xcode: CleanupXcodeMetadata
    let manager = FileManager()
    var apps: [CleanupApp] = []
    var entries: [CleanupEntry] = []
    var issues: [String] = []
    private(set) var hasPermissionIssues = false
    private var covered: Set<String> = []

    init(running: Set<String>, xcode: CleanupXcodeMetadata) {
        self.running = running
        self.xcode = xcode
    }

    func recordIssue(_ error: any Error, location: String) {
        // Use error codes rather than localized messages. A skipped link or
        // socket is a cleanup restriction, not evidence of denied access.
        var underlying = error as NSError
        var denied = false
        for _ in 0..<8 {
            if (underlying.domain == NSCocoaErrorDomain && underlying.code == CocoaError.Code.fileReadNoPermission.rawValue) ||
                (underlying.domain == NSPOSIXErrorDomain &&
                 [Int(POSIXError.Code.EACCES.rawValue), Int(POSIXError.Code.EPERM.rawValue)].contains(underlying.code)) {
                denied = true
                break
            }
            guard let next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            underlying = next
        }
        hasPermissionIssues = hasPermissionIssues || denied
        let detail = error.localizedDescription
        let note = detail.contains(location) ? detail : "\(location): \(detail)"
        issues.append("\(denied ? "Access denied · " : "")\(note)")
    }

    func children(_ url: URL) throws -> [URL] {
        guard manager.fileExists(atPath: url.path) else { return [] }
        try CleanupFiles.validateLocation(url)
        return try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }

    @discardableResult func append(title: String, urls: [URL], category: CleanupCategory, risk: CleanupRisk,
                detail: String, recovery: String, ownerID: String? = nil, ownerName: String? = nil,
                processes: [String] = [], registry: CleanupResource? = nil, lastUsed: Date? = nil,
                blocked: String? = nil, context: CleanupContext? = nil,
                duplicate: CleanupDuplicateEvidence? = nil) -> Bool {
        guard let first = urls.first, !urls.contains(where: { url in
            covered.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") || $0.hasPrefix(url.path + "/") })
        }) else { return false }
        do {
            let resources = try urls.map { try CleanupFiles.snapshot($0, application: category == .applications && $0.pathExtension == "app") }
            entries.append(CleanupEntry(id: first.path, title: title, category: category, risk: risk,
                detail: detail, recovery: recovery, resources: resources, action: .trash, estimatedBytes: 0,
                ownerID: ownerID, ownerName: ownerName, blockedReason: blocked ?? ownerID.flatMap {
                    running.contains($0) ? "Quit \(ownerName ?? $0) and rescan before cleanup." : nil
                }, lastUsed: lastUsed, processes: processes, modelRegistry: registry, context: context,
                ownerLastUsed: ownerID.flatMap { id in apps.first(where: { $0.id == id })?.lastUsed },
                duplicateEvidence: duplicate))
            covered.formUnion(urls.map(\.path))
            if let duplicate { covered.insert(duplicate.keeper.url.path) }
            return true
        } catch is CancellationError { /* The next scan checkpoint propagates cancellation. */ }
        catch { recordIssue(error, location: first.path) }
        return false
    }

    func add(_ rule: CleanupRule) {
        let root = CleanupFiles.home.appendingPathComponent(rule.path)
        guard manager.fileExists(atPath: root.path) else { return }
        do {
            let urls = rule.children ? try children(root) : [root]
            let owner = rule.owners.first
            let blocked = rule.owners.first(where: { running.contains($0) }).map { "Quit \($0) and rescan before cleanup." }
            for url in urls {
                let description = xcode.catalogItem(url, rule: rule)
                append(title: description.title,
                       urls: [url], category: rule.category, risk: rule.risk, detail: rule.detail,
                       recovery: rule.recovery, ownerID: owner, processes: rule.processes, blocked: blocked,
                       context: description.context)
            }
        } catch { recordIssue(error, location: root.path) }
    }

    func findApplications() throws {
        let roots = [URL(fileURLWithPath: "/Applications"), CleanupFiles.home.appendingPathComponent("Applications")]
        func walk(_ directory: URL, depth: Int) throws {
            guard manager.fileExists(atPath: directory.path), depth < 4 else { return }
            let urls: [URL]
            do { urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            catch { recordIssue(error, location: "Cannot list applications in \(directory.path)"); return }
            for url in urls {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true, !url.lastPathComponent.hasPrefix(".") else { continue }
                if url.pathExtension != "app" { try walk(url, depth: depth + 1); continue }
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                let metadata = MDItemCreate(kCFAllocatorDefault, url.path as CFString)
                let lastUsed = metadata.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                apps.append(CleanupApp(id: id, name: name, url: url, lastUsed: lastUsed))
                // An app cannot remove itself or its own data while it is running.
                if id == Bundle.main.bundleIdentifier { continue }
                append(title: name, urls: [url], category: .applications, risk: .personal,
                       detail: "Application bundle. Related files appear separately under this app and are never selected automatically. Removing the bundle does not revoke subscriptions or uninstall privileged helpers.",
                       recovery: "Restore from Trash or reinstall the app. Keep a backup of important app data.",
                       ownerID: id, ownerName: name, lastUsed: lastUsed)
            }
        }
        for root in roots { try walk(root, depth: 0) }
    }

    func findAppData() throws {
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for base in ["Library/Caches", "Library/Logs", "Library/Saved Application State", "Library/Preferences"] {
            let root = CleanupFiles.home.appendingPathComponent(base)
            let urls: [URL]
            do { urls = try children(root) }
            catch { recordIssue(error, location: root.path); continue }
            for url in urls {
                try Task.checkCancellation()
                let suffix = base.hasSuffix("Preferences") ? ".plist" : base.hasSuffix("State") ? ".savedState" : ""
                let id = suffix.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(url.lastPathComponent.hasSuffix(suffix) ? suffix.count : 0))
                guard id != Bundle.main.bundleIdentifier else { continue }
                let app = byID[id]
                // Tool caches have their own rules. Unknown entries are only offered
                // as possible leftovers when their name looks like a bundle identifier.
                guard app != nil || (id.split(separator: ".").count >= 3 && !id.contains(" ")) else { continue }
                let isCache = base.hasSuffix("Caches")
                let isLog = base.hasSuffix("Logs")
                let category: CleanupCategory = app == nil ? .leftovers : (isCache || isLog ? .appCaches : .applications)
                append(title: "\(app?.name ?? id) · \(isCache ? "cache" : isLog ? "logs" : base.hasSuffix("State") ? "saved state" : "preferences")",
                       urls: [url], category: category, risk: isCache ? .review : .personal,
                       detail: app == nil ? "Possible leftover: no matching app was found in /Applications or ~/Applications. It may still belong to a tool or an app installed elsewhere. Inspect it before removing."
                           : isCache ? "Cache belonging to \(app?.name ?? id). Check for offline downloads or other data the app cannot recreate."
                           : "App settings, logs or saved window state. These may contain data you want to keep.",
                       recovery: isCache ? "The app may recreate its cache. Offline data may need downloading again." : "Restore from Trash to recover these settings or records.",
                       ownerID: id, ownerName: app?.name ?? id)
            }
        }
        for app in apps where app.id != Bundle.main.bundleIdentifier {
            try Task.checkCancellation()
            // Identifier matches are explicit; product-name matches below are
            // separately described as uncertain. Never include shared containers.
            for base in ["Library/Application Support", "Library/Containers", "Library/Application Scripts"] {
                let url = CleanupFiles.home.appendingPathComponent(base).appendingPathComponent(app.id)
                guard manager.fileExists(atPath: url.path) else { continue }
                append(title: "\(app.name) · \(base.components(separatedBy: "/").last ?? "data")",
                       urls: [url], category: .applications, risk: .personal,
                       detail: "App data matching the exact bundle identifier \(app.id). May contain documents, accounts and settings. Shared containers, Keychain and privileged helpers are excluded.",
                       recovery: "Restore from Trash or a backup. Reinstalling the app does not restore its data.", ownerID: app.id, ownerName: app.name)
            }
            // Many apps store support data under their product name rather than
            // their identifier. Expose exact name matches as optional, personal
            // data, with the ownership uncertainty visible. Never include a
            // name shared by two different bundle identifiers.
            let knownNames: [String: [String]] = [
                "com.microsoft.VSCode": ["Code"],
                "com.todesktop.230313mzl4w4u92": ["Cursor"],
                "com.exafunction.windsurf": ["Windsurf"],
                "com.anthropic.claudefordesktop": ["Claude"],
                "ai.elementlabs.lmstudio": ["LM Studio"]
            ]
            for name in Set([app.name] + (knownNames[app.id] ?? [])).sorted() {
                let safeName = !name.isEmpty && !name.contains("/") && name != "." && name != ".."
                guard safeName, !apps.contains(where: { $0.name == name && $0.id != app.id }) else { continue }
                let root = CleanupFiles.home.appendingPathComponent("Library/Application Support").appendingPathComponent(name)
                if manager.fileExists(atPath: root.path) {
                    do {
                        for url in try children(root) {
                            append(title: "\(app.name) · \(url.lastPathComponent)", urls: [url], category: .applications, risk: .personal,
                                   detail: "Possible related data: the parent folder matches this app's product name or a known support-folder name. Verify ownership and contents before choosing it; another tool may share this folder.",
                                   recovery: "Restore from Trash or a backup. Reinstalling the app does not restore this data.",
                                   ownerID: app.id, ownerName: app.name)
                        }
                    } catch { recordIssue(error, location: root.path) }
                }
            }
        }
    }

    /// Path inside the scanned folder, so a generic module like `app` still shows its project.
    static func projectLabel(_ directory: URL, root: URL) -> String {
        let base = root.standardizedFileURL.pathComponents, path = directory.standardizedFileURL.pathComponents
        guard path.count > base.count, Array(path.prefix(base.count)) == base else { return directory.lastPathComponent }
        return path.dropFirst(base.count).joined(separator: "/")
    }

    func findProjects(_ root: URL) throws {
        do { try CleanupFiles.validateLocation(root) }
        catch { recordIssue(error, location: root.path); return }
        guard StorageScanner.allowed(root) else { issues.append("Choose a personal project folder outside Library and hidden directories: \(root.path)"); return }
        var visited = 0
        func walk(_ directory: URL, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 24, visited < 100_000 else { return }
            visited += 1
            let urls: [URL]
            do { urls = try children(directory) }
            catch { recordIssue(error, location: directory.path); return }
            let names = Set(urls.map(\.lastPathComponent))
            for url in urls {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isUbiquitousItemKey]),
                      values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true,
                      values.isUbiquitousItem != true else { continue }
                if let rule = CleanupCatalog.projects.first(where: { $0.name == url.lastPathComponent && ($0.markers.isEmpty || $0.markers.contains(where: names.contains)) }) {
                    append(title: "\(Self.projectLabel(directory, root: root)) · \(rule.name)", urls: [url], category: .projects,
                           risk: rule.risk, detail: rule.detail + " Project: \(directory.path). Modification dates are not proof of last use.",
                           recovery: rule.recovery, processes: rule.processes)
                } else if !url.lastPathComponent.hasPrefix("."), StorageScanner.allowed(url) {
                    try walk(url, depth: depth + 1)
                }
            }
            if depth == 24 { issues.append("Project discovery stopped at 24 folder levels: \(directory.path)") }
        }
        try walk(root, depth: 0)
        if visited >= 100_000 { issues.append("Project discovery reached its 100,000-folder limit in \(root.path). Add a smaller project folder.") }
    }

    func findModels() throws {
        let environment = ProcessInfo.processInfo.environment
        let hf = environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) } ??
            environment["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") } ??
            CleanupFiles.home.appendingPathComponent(".cache/huggingface/hub")
        do {
            for url in try children(hf) where url.lastPathComponent.hasPrefix("models--") || url.lastPathComponent.hasPrefix("datasets--") {
                try Task.checkCancellation()
                append(title: "Hugging Face · \(url.lastPathComponent.replacingOccurrences(of: "--", with: "/"))", urls: [url], category: .models,
                       risk: .review, detail: "This repository's cached revisions and blobs. Shared revisions stay together; links inside the repository are not followed.",
                       recovery: "Download the repository again. Private or removed models may no longer be available.", processes: ["python", "python3", "hf", "huggingface-cli"])
            }
        } catch { recordIssue(error, location: "Hugging Face") }
        for path in [".lmstudio/models", ".cache/lm-studio/models"] {
            let root = CleanupFiles.home.appendingPathComponent(path)
            guard manager.fileExists(atPath: root.path) else { continue }
            func walk(_ directory: URL, depth: Int) throws {
                guard depth < 6 else { return }
                for url in try children(directory) {
                    try Task.checkCancellation()
                    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                    guard values.isSymbolicLink != true else { continue }
                    if values.isDirectory == true { try walk(url, depth: depth + 1) }
                    else if values.isRegularFile == true, ["gguf", "safetensors"].contains(url.pathExtension.lowercased()) {
                        append(title: "LM Studio · \(url.lastPathComponent)", urls: [url], category: .models, risk: .review,
                               detail: "A local model file. Keep all shards of a model you still use.", recovery: "Download this exact model file again or restore it from Trash.",
                               ownerID: "ai.elementlabs.lmstudio", ownerName: "LM Studio", processes: ["lms", "llmster"])
                    }
                }
            }
            do { try walk(root, depth: 0) } catch { recordIssue(error, location: "LM Studio") }
        }
        let ollama = environment["OLLAMA_MODELS"].map { URL(fileURLWithPath: $0) } ?? CleanupFiles.home.appendingPathComponent(".ollama/models")
        do { try findOllama(ollama) } catch is CancellationError { throw CancellationError() }
        catch { recordIssue(error, location: "Ollama") }
    }

    func findOllama(_ root: URL) throws {
        let manifests = root.appendingPathComponent("manifests")
        guard manager.fileExists(atPath: manifests.path) else { return }
        let registry = try CleanupFiles.snapshot(manifests)
        struct Manifest { let url: URL; let digests: Set<String> }
        var models: [Manifest] = []
        func walk(_ directory: URL, depth: Int) throws {
            guard depth < 8 else { throw StorageError("Unexpected Ollama manifest layout.") }
            for url in try children(directory) {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw StorageError("Linked Ollama manifests are excluded.") }
                if values.isDirectory == true { try walk(url, depth: depth + 1); continue }
                guard values.isRegularFile == true, (values.fileSize ?? 0) < 4_194_304,
                      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      let config = object["config"] as? [String: Any], let layers = object["layers"] as? [[String: Any]] else {
                    throw StorageError("An Ollama manifest could not be read. No Ollama models were offered.")
                }
                let references = ([config] + layers).compactMap { $0["digest"] as? String }
                guard references.count == layers.count + 1 else { throw StorageError("An Ollama model has incomplete blob references.") }
                let digests = Set(references)
                guard !digests.isEmpty, digests.allSatisfy({ $0.hasPrefix("sha256:") && $0.count == 71 && $0.dropFirst(7).allSatisfy(\.isHexDigit) }) else {
                    throw StorageError("An Ollama model has an unsupported digest.")
                }
                models.append(Manifest(url: url, digests: digests))
            }
        }
        try walk(manifests, depth: 0)
        try CleanupFiles.validate(registry)
        let counts = models.reduce(into: [String: Int]()) { counts, model in
            for digest in model.digests { counts[digest, default: 0] += 1 }
        }
        for model in models {
            let exclusive = model.digests.filter { counts[$0] == 1 }.sorted().map {
                root.appendingPathComponent("blobs").appendingPathComponent($0.replacingOccurrences(of: ":", with: "-"))
            }
            let name = String(model.url.path.dropFirst(manifests.path.count + 1))
            append(title: "Ollama · \(name)", urls: [model.url] + exclusive, category: .models, risk: .review,
                   detail: "Model manifest and blobs referenced only by this model. Shared blobs are retained and excluded from this size. Quit Ollama's app and background server first. Removing several models can leave shared blobs behind; rescan remaining models between cleanups.",
                   recovery: "Restore every listed file from Trash, or pull this model again. Custom models may require a backup.",
                   ownerID: "com.electron.ollama", ownerName: "Ollama", processes: ["ollama"], registry: registry)
        }
    }
}
