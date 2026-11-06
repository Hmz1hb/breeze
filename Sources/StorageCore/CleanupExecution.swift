import Darwin
import Foundation

public struct CleanupExecutionOutcome: Sendable {
    public let completed: Set<String>
    public let trashedFiles: Int
    public let permanentActions: Int
    public let failures: [String]
    public let blockers: [CleanupProcessBlocker]
}

public enum CleanupExecution {
    public static func review(selection: Set<String>, inventory: CleanupInventory) throws -> [CleanupEntry] {
        let entries = inventory.entries.filter { selection.contains($0.id) }
        guard !entries.isEmpty, entries.count == selection.count else { throw StorageError("Choose items from the current cleanup scan.") }
        guard entries.allSatisfy({ $0.blockedReason == nil }) else { throw StorageError("Quit the running apps listed beside selected items, then rescan.") }
        for evidence in entries.compactMap(\.duplicateEvidence) {
            guard !entries.flatMap(\.resources).contains(where: {
                $0.url == evidence.keeper.url || CleanupFiles.inside(evidence.keeper.url, $0.url)
            }) else { throw StorageError("Keep the preserved copy of each duplicate group. Scan again before cleanup.") }
        }
        return entries
    }

    @concurrent public static func clean(selection: Set<String>, inventory: CleanupInventory,
                                         progress: @escaping @Sendable (String) async -> Void = { _ in },
                                         advancement: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> CleanupExecutionOutcome {
        let entries = try review(selection: selection, inventory: inventory)
        var registries: [URL: CleanupResource] = [:]
        // Validate the whole filesystem selection before moving anything.
        for entry in entries {
            try Task.checkCancellation()
            await progress("Validating \(entry.title)")
            try await checkRunning(entry)
            for resource in entry.resources {
                try CleanupFiles.validate(resource, application: entry.category == .applications && resource.url.pathExtension == "app")
            }
            try validateDuplicates(entry)
            if let registry = entry.modelRegistry { registries[registry.url] = registry }
        }
        for registry in registries.values { try CleanupFiles.validate(registry) }
        var completed: Set<String> = []
        var trashed = 0
        var permanent = 0
        var failures: [String] = []
        var blockers: [CleanupProcessBlocker] = []
        let manager = FileManager()
        // Move related data before application bundles, so a failed data move
        // does not rely on a bundle that was already uninstalled.
        let ordered = entries.sorted {
            let leftApp = $0.resources.first?.url.pathExtension == "app"
            let rightApp = $1.resources.first?.url.pathExtension == "app"
            return leftApp == rightApp ? $0.id < $1.id : !leftApp
        }
        for (index, entry) in ordered.enumerated() {
            if Task.isCancelled { failures.append("Cleanup stopped. Scan again to see current files."); break }
            await advancement(index, ordered.count)
            await progress("Removing \(entry.title)")
            do {
                try await checkRunning(entry)
                try validateDuplicates(entry)
                if let registry = entry.modelRegistry, let expected = registries[registry.url] { try CleanupFiles.validate(expected) }
                switch entry.action {
                case .trash:
                    for resource in entry.resources {
                        try Task.checkCancellation()
                        if let evidence = entry.duplicateEvidence { try validateDuplicate(evidence.keeper, evidence: evidence) }
                        try CleanupFiles.validate(resource, application: entry.category == .applications && resource.url.pathExtension == "app")
                        try manager.trashItem(at: resource.url, resultingItemURL: nil)
                        trashed += 1
                    }
                default:
                    try await CleanupTools.remove(entry)
                    permanent += 1
                }
                completed.insert(entry.id)
                if let registry = entry.modelRegistry { registries[registry.url] = try CleanupFiles.snapshot(registry.url) }
            } catch {
                if let running = error as? CleanupProcessesRunning {
                    blockers += running.blockers
                    failures.append("\(entry.title): a process started using this item. Review its running processes to continue.")
                } else {
                    failures.append("\(entry.title): \(error.localizedDescription). Some listed files may already have moved; inspect Trash and rescan.")
                }
                // Any partial model move invalidates our shared-reference accounting.
                if entry.modelRegistry != nil || error is CancellationError { break }
            }
            await advancement(index + 1, ordered.count)
        }
        return CleanupExecutionOutcome(completed: completed, trashedFiles: trashed, permanentActions: permanent, failures: failures, blockers: blockers)
    }

    private static func checkRunning(_ entry: CleanupEntry) async throws {
        let blockers = try await CleanupProcesses.blockers(for: [entry])
        if !blockers.isEmpty { throw CleanupProcessesRunning(blockers: blockers) }
    }

    private static func validateDuplicates(_ entry: CleanupEntry) throws {
        guard let evidence = entry.duplicateEvidence else { return }
        for file in [evidence.keeper] + evidence.copies {
            try validateDuplicate(file, evidence: evidence)
        }
    }

    private static func validateDuplicate(_ file: StorageFile, evidence: CleanupDuplicateEvidence) throws {
        try StorageScanner.validate(file, root: evidence.root)
        guard try StorageScanner.digest(file) == evidence.digest else {
            throw StorageError("A duplicate or its preserved copy changed. Scan again before cleanup.")
        }
    }
}
