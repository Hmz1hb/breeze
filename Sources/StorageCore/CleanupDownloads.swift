import Foundation

extension CleanupInventoryBuilder {
    func findDownloads(progress: @escaping @Sendable (String) async -> Void) async throws {
        let root = CleanupFiles.home.appendingPathComponent("Downloads")
        guard manager.fileExists(atPath: root.path) else { return }
        do {
            try CleanupFiles.validateLocation(root)
            let scan = try await StorageScanner.scan(root: root, limit: 25_000, includingInstallerFiles: true,
                progress: { update in await progress("Downloads · \(update.phase)") })
            if scan.reachedLimit { issues.append("Downloads discovery reached 25,000 files. Duplicate and installer results cover only those files.") }
            if scan.unreadable > 0 || scan.duplicateReadFailures > 0 {
                issues.append("Downloads: \(scan.unreadable) unreadable locations; \(scan.duplicateReadFailures) incomplete duplicate checks.")
            }
            // Offer only excess copies. Reserving the keeper also prevents it from
            // appearing again as an installer in the same cleanup inventory.
            for group in scan.duplicates {
                try Task.checkCancellation()
                let files = group.files.sorted {
                    $0.url.path.count == $1.url.path.count ? $0.id < $1.id : $0.url.path.count < $1.url.path.count
                }
                guard let keeper = files.first else { continue }
                let copies = Array(files.dropFirst())
                do {
                    for file in files { try StorageScanner.validate(file, root: root) }
                    append(title: "\(copies.count) duplicate \(copies.count == 1 ? "copy" : "copies") · \(keeper.url.lastPathComponent)",
                        urls: copies.map(\.url), category: .duplicates, risk: .review,
                        detail: "These Downloads files have identical full SHA-256 content hashes. Only the excess copies are listed for removal. The copy to keep is rechecked before any copies move.",
                        recovery: "Restore extra copies from Trash. One verified copy stays in its current folder.",
                        context: .init(summary: "Keep: \(keeper.url.lastPathComponent) · \(copies.count) extra \(copies.count == 1 ? "copy" : "copies")",
                            sections: [.init(title: "Copy to keep", text: keeper.url.path),
                                       .init(title: "Extra copies", text: copies.map(\.url.path).joined(separator: "\n"))]),
                        duplicate: .init(root: root, keeper: keeper, copies: copies, digest: group.id))
                } catch is CancellationError { throw CancellationError() }
                catch { recordIssue(error, location: keeper.url.path) }
            }
            for file in scan.files where ["dmg", "pkg", "iso"].contains(file.url.pathExtension.lowercased()) {
                try Task.checkCancellation()
                do {
                    try StorageScanner.validate(file, root: root)
                    append(title: file.url.lastPathComponent, urls: [file.url], category: .downloads, risk: .review,
                        detail: "Downloaded installer or disk image. Removing the download leaves installed apps in place. Verify installation is complete and eject any mounted image first. An ISO may be an operating-system image you still need.",
                        recovery: "Restore from Trash or download this version again if it is still available.",
                        context: .init(summary: "Downloads · installer or disk image",
                            sections: [.init(title: "What you can reclaim", text: "Only this downloaded file. Installed applications and their data are kept. Age alone does not show whether installation is complete.")]))
                } catch is CancellationError { throw CancellationError() }
                catch { recordIssue(error, location: file.url.path) }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { recordIssue(error, location: root.path) }
    }
}
