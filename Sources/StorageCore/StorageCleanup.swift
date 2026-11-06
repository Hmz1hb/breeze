import Foundation

public struct CleanupOutcome: Sendable {
    public let moved: Set<String>
    public let failures: [String]
}

public enum StorageCleanup {
    /// Validates the entire selection before any files move. No automatic selection or permanent deletion.
    public static func review(selection: Set<String>, scan: StorageScan) throws -> [StorageFile] {
        guard scan.duplicatesComplete else { throw StorageError("Rescan to finish duplicate checks before cleanup.") }
        let files = scan.files.filter { selection.contains($0.id) }
        guard !files.isEmpty, files.count == selection.count else { throw StorageError("Choose files from the current scan.") }
        for group in scan.duplicates where group.files.contains(where: { selection.contains($0.id) }) {
            guard group.files.contains(where: { !selection.contains($0.id) }) else {
                throw StorageError("Keep at least one copy of every duplicate group.")
            }
        }
        return files
    }

    @concurrent public static func moveToTrash(selection: Set<String>, scan: StorageScan) async throws -> CleanupOutcome {
        let files = try review(selection: selection, scan: scan)
        for file in files { try StorageScanner.validate(file, root: scan.root) }
        // A missing or changed keeper must never justify removing its remaining copy.
        for group in scan.duplicates where group.files.contains(where: { selection.contains($0.id) }) {
            var hasKeeper = false
            for keeper in group.files where !selection.contains(keeper.id) {
                try Task.checkCancellation()
                if (try? StorageScanner.validate(keeper, root: scan.root)) != nil,
                   (try? StorageScanner.digest(keeper)) == group.id { hasKeeper = true; break }
            }
            guard hasKeeper else { throw StorageError("A duplicate copy to keep is missing or changed. Scan again.") }
        }
        var moved: Set<String> = []
        var failures: [String] = []
        let manager = FileManager()
        for file in files {
            do {
                try StorageScanner.validate(file, root: scan.root)
                try manager.trashItem(at: file.url, resultingItemURL: nil)
                moved.insert(file.id)
            } catch { failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
        }
        return CleanupOutcome(moved: moved, failures: failures)
    }
}
