import AppKit
import Observation
import StorageCore

private final class StorageFolderAccess: Sendable {
    let url: URL
    let granted: Bool
    init(_ url: URL) { self.url = url; granted = url.startAccessingSecurityScopedResource() }
    deinit { if granted { url.stopAccessingSecurityScopedResource() } }
}

private struct StorageInventory: Sendable {
    let scan: StorageScan
    let byID: [String: StorageFile]
    let suggested: [StorageFile]

    @concurrent static func prepare(_ scan: StorageScan) async -> StorageInventory {
        StorageInventory(scan: scan, byID: Dictionary(uniqueKeysWithValues: scan.files.map { ($0.id, $0) }),
                         suggested: scan.files.filter { $0.suggestion(now: scan.finished) != nil })
    }
}

@MainActor @Observable
final class StorageModel {
    enum Workspace: String, CaseIterable { case overview = "Disk overview", files = "Files & cleanup", cleanup = "Cleanup & apps" }
    var workspace = Workspace.overview
    let monitor = StorageMonitor()
    let cleanup = StorageCleanupModel()
    enum Tab: String, CaseIterable { case map = "Browse files", duplicates = "Duplicates", suggestions = "Worth reviewing" }
    var tab = Tab.map
    var scan: StorageScan?
    var scanning = false
    var cleaning = false
    var progress = ""
    var fileCount = 0
    var message: String?
    var selection: Set<String> = []
    var focusedFolder: URL?
    var nodes: [StorageNode] = []
    var inspected: StorageFile?
    var reviewFiles: [StorageFile] = []
    var showingReview = false
    var visibleRows = 100
    private var task: Task<Void, Never>?
    private var byID: [String: StorageFile] = [:]
    private var folderAccess: StorageFolderAccess?
    var suggestedFiles: [StorageFile] = []
    var selectedFiles: [StorageFile] { selection.compactMap { byID[$0] }.sorted { $0.id < $1.id } }
    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.bytes } }
    var busy: Bool { scanning || cleaning }
    func file(_ id: String) -> StorageFile? { byID[id] }

    func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan folder"
        panel.message = "Choose a personal folder to explore. Breeze excludes system data, hidden items, libraries and app bundles."
        panel.begin { response in
            if response == .OK, let url = panel.url { self.start(url) }
        }
    }

    func start(_ url: URL) {
        guard !busy else { return }
        workspace = .files
        scanning = true; progress = "Reading folders"; fileCount = 0
        message = nil; selection = []; inspected = nil; showingReview = false
        StorageThumbnailLoader.shared.clearCache()
        task = Task { [self] in
            let access = StorageFolderAccess(url)
            defer { scanning = false; task = nil }
            do {
                let result = try await StorageScanner.scan(root: url, inventory: { [self] partial in
                    let prepared = await StorageInventory.prepare(partial)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        let folder = scan?.root == partial.root ? focusedFolder ?? partial.root : partial.root
                        folderAccess = access
                        scan = partial; byID = prepared.byID; suggestedFiles = prepared.suggested
                        focus(folder)
                    }
                }) { [self] update in
                    await MainActor.run {
                        self.progress = update.phase; self.fileCount = update.files
                    }
                }
                try Task.checkCancellation()
                scan = result
            } catch is CancellationError {
                message = scan?.duplicatesComplete == false
                    ? "Scan stopped. Available files can still be browsed. Rescan to finish duplicate checks before cleanup."
                    : "Scan cancelled. Previous results, if any, are unchanged."
            }
            catch { message = error.localizedDescription }
        }
    }

    func cancel() { task?.cancel(); progress = "Stopping scan…" }

    func focus(_ folder: URL) {
        focusedFolder = folder; visibleRows = 100; inspected = nil
        guard let scan else { nodes = []; return }
        let rootPath = scan.root.path
        guard folder.path == rootPath || folder.path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else {
            focusedFolder = scan.root; nodes = scan.directoryIndex[rootPath] ?? []; return
        }
        nodes = scan.directoryIndex[folder.path] ?? []
    }

    func inspect(_ node: StorageNode) {
        if node.isDirectory { focus(node.url) } else { inspected = byID[node.id] }
    }

    func toggle(_ file: StorageFile) {
        guard !busy, scan?.duplicatesComplete == true else { return }
        if selection.contains(file.id) { selection.remove(file.id); return }
        if let group = scan?.duplicates.first(where: { $0.files.contains(where: { $0.id == file.id }) }),
           group.files.filter({ !selection.contains($0.id) }).count <= 1 {
            message = "Keep at least one copy of every duplicate group."; return
        }
        selection.insert(file.id)
    }

    func prepareReview() {
        guard let scan, !busy else { return }
        do { reviewFiles = try StorageCleanup.review(selection: selection, scan: scan); showingReview = true }
        catch { message = error.localizedDescription }
    }

    func trashReviewed() {
        guard let scan, !busy, !reviewFiles.isEmpty else { return }
        let reviewedSelection = Set(reviewFiles.map(\.id))
        showingReview = false; cleaning = true; message = nil
        task = Task {
            let access = scan.root.startAccessingSecurityScopedResource()
            defer { if access { scan.root.stopAccessingSecurityScopedResource() }; cleaning = false; task = nil }
            do {
                let outcome = try await StorageCleanup.moveToTrash(selection: reviewedSelection, scan: scan)
                message = "Moved \(outcome.moved.count) file(s) to Trash. Restore them in Finder if needed. Disk space is released when Trash is emptied."
                if !outcome.failures.isEmpty { message! += "\n" + outcome.failures.prefix(5).joined(separator: "\n") }
                applyMovedFiles(outcome.moved)
                reviewFiles = []
            } catch { message = error.localizedDescription }
        }
    }

    /// Keep the current folder (even when emptied) and retain failed items for retry.
    func applyMovedFiles(_ moved: Set<String>) {
        guard let updated = scan?.removingFiles(moved) else { return }
        scan = updated
        byID = Dictionary(uniqueKeysWithValues: updated.files.map { ($0.id, $0) })
        suggestedFiles = updated.files.filter { $0.suggestion(now: updated.finished) != nil }
        selection.subtract(moved)
        if let inspected, moved.contains(inspected.id) { self.inspected = nil }
        nodes = updated.directoryIndex[(focusedFolder ?? updated.root).path] ?? []
        StorageThumbnailLoader.shared.clearCache()
    }
}
