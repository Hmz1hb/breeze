import CleanupAssistant
import Foundation
import Testing
@testable import StorageCore

// Only failure paths run here: a successful cleanup would move fixtures into the user's real Trash.

private func trashEntry(_ id: String, _ resources: [CleanupResource], category: CleanupCategory = .downloads,
                        blocked: String? = nil) -> CleanupEntry {
    CleanupTools.entry(id: id, title: id, category: category, risk: .review, detail: "", recovery: "",
                       action: .trash, bytes: 10, resources: resources, blocked: blocked)
}

private func duplicatePair(_ fixture: Fixture) async throws -> (StorageScan, keeper: StorageFile, copy: StorageFile) {
    _ = try fixture.file("a")
    _ = try fixture.file("b")
    let scan = try await StorageScanner.scan(root: fixture.root)
    return (scan, try #require(scan.files.first), try #require(scan.files.last))
}

@Test func cleanupRefusesToRemoveTheDuplicateKeeper() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let (scan, keeper, copy) = try await duplicatePair(fixture)
    var entry = trashEntry("dup", [try CleanupFiles.snapshot(keeper.url)], category: .duplicates)
    entry.duplicateEvidence = CleanupDuplicateEvidence(root: scan.root, keeper: keeper, copies: [copy],
                                                       digest: try StorageScanner.digest(keeper))
    let inventory = CleanupInventory(entries: [entry], issues: [], finished: .now)
    #expect(throws: StorageError.self) { try CleanupExecution.review(selection: ["dup"], inventory: inventory) }
}

@Test func changedDuplicateKeeperBlocksCleanupBeforeAnyMove() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let (scan, keeper, copy) = try await duplicatePair(fixture)
    var entry = trashEntry("dup", [try CleanupFiles.snapshot(copy.url)], category: .duplicates)
    entry.duplicateEvidence = CleanupDuplicateEvidence(root: scan.root, keeper: keeper, copies: [copy],
                                                       digest: try StorageScanner.digest(keeper))
    let inventory = CleanupInventory(entries: [entry], issues: [], finished: .now)
    try Data("the preserved copy changed".utf8).write(to: keeper.url)
    await #expect(throws: StorageError.self) {
        try await CleanupExecution.clean(selection: ["dup"], inventory: inventory)
    }
    #expect(FileManager.default.fileExists(atPath: copy.url.path))
}

@Test func folderChangedSinceScanBlocksCleanupBeforeAnyMove() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let kept = try fixture.file("cache/old")
    let inventory = CleanupInventory(
        entries: [trashEntry("cache", [try CleanupFiles.snapshot(kept.deletingLastPathComponent())])],
        issues: [], finished: .now)
    _ = try fixture.file("cache/new")
    await #expect(throws: StorageError.self) {
        try await CleanupExecution.clean(selection: ["cache"], inventory: inventory)
    }
    #expect(FileManager.default.fileExists(atPath: kept.path))
}

@Test func linkedCleanupRootsAndAncestorsAreRejected() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let real = try fixture.file("real/data").deletingLastPathComponent()
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(throws: StorageError.self) { try CleanupFiles.snapshot(link) }
    #expect(throws: StorageError.self) { try CleanupFiles.snapshot(link.appendingPathComponent("data")) }
}

@Test func blockedOrUnknownItemsCannotBeReviewed() throws {
    let inventory = CleanupInventory(entries: [trashEntry("busy", [], blocked: "Quit Example first.")],
                                     issues: [], finished: .now)
    #expect(throws: StorageError.self) { try CleanupExecution.review(selection: ["busy"], inventory: inventory) }
    #expect(throws: StorageError.self) { try CleanupExecution.review(selection: ["missing"], inventory: inventory) }
}

@Test func proposalsMustMatchTheCurrentSharedScan() throws {
    let inventory = CleanupInventory(entries: [trashEntry("cache", [])], issues: [], finished: .now)
    let snapshot = AssistantSnapshot(inventory: inventory)
    let item = AssistantProposalItem(id: "item-1", reason: "Rebuildable cache.")
    func propose(_ items: [AssistantProposalItem], to other: AssistantSnapshot? = nil, id: String? = nil) throws {
        let target = other ?? snapshot
        try AssistantProposal(snapshotID: id ?? target.id, summary: "Free space.", items: items).validate(against: target)
    }
    try propose([item])
    #expect(throws: StorageError.self) { try propose([item], id: UUID().uuidString) }
    #expect(throws: StorageError.self) { try propose([AssistantProposalItem(id: "item-2", reason: "Unknown.")]) }
    #expect(throws: StorageError.self) { try propose([item, item]) }
    #expect(throws: StorageError.self) { try propose([]) }
    let old = Date.now.addingTimeInterval(-5 * 60 * 60)
    let expired = AssistantSnapshot(inventory: CleanupInventory(entries: inventory.entries, issues: [], finished: old), now: old)
    #expect(throws: StorageError.self) { try propose([item], to: expired) }
}

@Test func projectLabelsShowPathInsideScannedFolder() {
    let root = URL(fileURLWithPath: "/Users/me/Projects")
    #expect(CleanupInventoryBuilder.projectLabel(root.appendingPathComponent("MyGame/android/app"), root: root) == "MyGame/android/app")
    #expect(CleanupInventoryBuilder.projectLabel(root.appendingPathComponent("Site"), root: root) == "Site")
    #expect(CleanupInventoryBuilder.projectLabel(root, root: root) == "Projects")
}

@Test func dockerImageTitlesNameUntaggedImages() {
    let id = "sha256:7d6c0d730233037557819b98eb19b4ea9ccada93f7d3a0c9bcd23f3ecaef9d71"
    #expect(CleanupTools.dockerImageTitle(["Repository": "<none>", "Tag": "<none>", "CreatedSince": "3 weeks ago"], id: id)
        == "Untagged image · 7d6c0d730233 · created 3 weeks ago")
    #expect(CleanupTools.dockerImageTitle(["Repository": "api", "Tag": "<none>"], id: id) == "api (untagged)")
    #expect(CleanupTools.dockerImageTitle(["Repository": "api", "Tag": "latest"], id: id) == "api:latest")
}
