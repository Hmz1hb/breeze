import CoreGraphics
import Foundation
import Testing
@testable import StorageCore

struct Fixture {
    let root: URL
    init() throws {
        // /private is intentionally excluded by the production scanner.
        // Use the project workspace, never a user's personal files.
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ name: String, data: Data = Data("matching contents".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func duplicatesUseAllContentsRatherThanNamesOrPrefixes() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let data = Data(repeating: 42, count: 70_000)
    _ = try fixture.file("a/original.bin", data: data)
    _ = try fixture.file("b/renamed.bin", data: data)
    var changed = data; changed[69_999] = 43
    _ = try fixture.file("c/original.bin", data: changed)
    _ = try fixture.file("empty-a", data: Data())
    _ = try fixture.file("empty-b", data: Data())
    let result = try await StorageScanner.scan(root: fixture.root)
    #expect(result.files.count == 5)
    #expect(result.duplicates.count == 1)
    #expect(result.duplicates.first?.files.count == 2)
    #expect(result.extraDuplicateBytes == 70_000)
}

@Test func linksHiddenDataLibrariesAndPackagesAreExcluded() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let original = try fixture.file("original")
    _ = try fixture.file(".hidden")
    _ = try fixture.file("Library/data")
    _ = try fixture.file("Example.app/Contents/data")
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("alias"), withDestinationURL: original)
    try FileManager.default.linkItem(at: original, to: fixture.root.appendingPathComponent("hardlink"))
    let result = try await StorageScanner.scan(root: fixture.root)
    #expect(result.files.count == 1)
    #expect(result.duplicates.isEmpty)
    #expect(result.skipped >= 3)
}

@Test func cleanupRequiresAKeeperAndCurrentFiles() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    _ = try fixture.file("a")
    _ = try fixture.file("b")
    let result = try await StorageScanner.scan(root: fixture.root)
    let all = Set(result.files.map(\.id))
    #expect(throws: StorageError.self) { try StorageCleanup.review(selection: all, scan: result) }
    let file = try #require(result.files.first)
    #expect(try StorageCleanup.review(selection: [file.id], scan: result).count == 1)
    try Data("changed contents".utf8).write(to: file.url)
    #expect(throws: StorageError.self) { try StorageScanner.validate(file, root: result.root) }
    #expect(throws: StorageError.self) { try StorageCleanup.review(selection: ["unknown"], scan: result) }
}

@Test func missingKeeperBlocksTrashBeforeAnyMove() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    _ = try fixture.file("a")
    _ = try fixture.file("b")
    let result = try await StorageScanner.scan(root: fixture.root)
    let selected = try #require(result.files.first)
    let keeper = try #require(result.files.last)
    try FileManager.default.removeItem(at: keeper.url)
    await #expect(throws: StorageError.self) {
        try await StorageCleanup.moveToTrash(selection: [selected.id], scan: result)
    }
    #expect(FileManager.default.fileExists(atPath: selected.id))
}

@Test func partialScansAndCancellationAreExplicit() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    _ = try fixture.file("a")
    _ = try fixture.file("b")
    let result = try await StorageScanner.scan(root: fixture.root, limit: 1)
    #expect(result.reachedLimit)
    #expect(result.files.count == 1)
    let task = Task { try await StorageScanner.scan(root: fixture.root) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func suggestionsUseAgeAsEvidenceRatherThanClaimingUnused() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let installer = try fixture.file("old.dmg")
    _ = try fixture.file("current.dmg")
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: installer.path)
    let result = try await StorageScanner.scan(root: fixture.root)
    #expect(result.files.first(where: { $0.url == installer })?.suggestion()?.contains("unchanged") == true)
    #expect(result.files.first(where: { $0.url.lastPathComponent == "current.dmg" })?.suggestion() == nil)
}

@Test func folderAggregationAndTreemapPreserveSizes() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    _ = try fixture.file("a/one", data: Data(repeating: 1, count: 60))
    _ = try fixture.file("a/two", data: Data(repeating: 2, count: 30))
    _ = try fixture.file("b", data: Data(repeating: 3, count: 10))
    let result = try await StorageScanner.scan(root: fixture.root)
    let nodes = StorageNode.children(of: result.root, files: result.files)
    #expect(nodes.count == 2)
    #expect(nodes[0].bytes == 90 && nodes[0].count == 2 && nodes[0].isDirectory)
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
    let tiles = StorageTreemap.layout(weights: [60, 30, 10, 0], in: bounds)
    #expect(tiles.count == 3)
    for tile in tiles {
        #expect(bounds.contains(tile.rect))
        #expect(abs(tile.rect.width * tile.rect.height / 150_000 - Double([60, 30, 10][tile.index]) / 100) < 0.00001)
    }
    for i in tiles.indices {
        for j in tiles.indices where i < j {
            let overlap = tiles[i].rect.intersection(tiles[j].rect)
            #expect(overlap.isNull || overlap.width * overlap.height < 0.00001)
        }
    }
    #expect(StorageTreemap.layout(weights: [0, 0], in: bounds).isEmpty)
}

@Test func systemFoldersAreRejected() async {
    await #expect(throws: StorageError.self) { try await StorageScanner.scan(root: URL(fileURLWithPath: "/System")) }
}

@Test func removingMovedFilesRecalculatesDuplicateGroupsAndTotals() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    _ = try fixture.file("a")
    _ = try fixture.file("b")
    _ = try fixture.file("c")
    _ = try fixture.file("different", data: Data("unique".utf8))
    let result = try await StorageScanner.scan(root: fixture.root)
    let group = try #require(result.duplicates.first)
    let updated = result.removingFiles([group.files[0].id])
    #expect(updated.root == result.root)
    #expect(updated.files.count == 3)
    #expect(updated.bytes == result.bytes - group.files[0].bytes)
    #expect(updated.duplicates.first?.files.count == 2)
    #expect(updated.extraDuplicateBytes == group.files[0].bytes)
    #expect(updated.finished == result.finished)
    #expect(updated.reachedLimit == result.reachedLimit)
    let last = updated.removingFiles([group.files[1].id])
    #expect(last.duplicates.isEmpty)
    #expect(last.extraDuplicateBytes == 0)
    #expect(last.files.contains { $0.id == group.files[2].id })
}

@Test func directoryIndexMatchesFolderAggregationForLargeNestedScans() {
    let root = URL(fileURLWithPath: "/Users/test/Storage")
    let files = (0..<10_000).map { index in
        let url = root.appendingPathComponent("folder-\(index % 50)/nested/file-\(index).mp4")
        return StorageFile(url: url, bytes: Int64(index), allocatedBytes: Int64(index), modified: .now,
                           category: .video, stamp: FileStamp(device: 1, inode: UInt64(index), size: Int64(index), seconds: 0, nanoseconds: 0))
    }
    let indexed = StorageNode.directoryIndex(root: root, files: files)
    for folder in [root, root.appendingPathComponent("folder-0"), root.appendingPathComponent("folder-49/nested")] {
        let expected = StorageNode.children(of: folder, files: files)
        let actual = indexed[folder.path] ?? []
        #expect(actual.map(\.id) == expected.map(\.id))
        #expect(actual.map(\.bytes) == expected.map(\.bytes))
        #expect(actual.map(\.count) == expected.map(\.count))
        #expect(actual.map(\.isDirectory) == expected.map(\.isDirectory))
    }
    #expect(indexed[root.path]?.reduce(0) { $0 + $1.bytes } == files.reduce(0) { $0 + $1.bytes })
}

private actor PartialInventoryRecorder {
    var partial: StorageScan?
    func record(_ scan: StorageScan) { partial = scan }
}

@Test func inventoryIsBrowsableBeforeDuplicateChecksAndCannotBeCleanedUp() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    _ = try fixture.file("a")
    _ = try fixture.file("b")
    let recorder = PartialInventoryRecorder()
    let scanTask = Task {
        try await StorageScanner.scan(root: fixture.root, inventory: { partial in
            await recorder.record(partial)
            withUnsafeCurrentTask { $0?.cancel() }
        })
    }
    await #expect(throws: CancellationError.self) { try await scanTask.value }
    let partial = try #require(await recorder.partial)
    #expect(!partial.duplicatesComplete)
    #expect(partial.files.count == 2)
    #expect(partial.directoryIndex[partial.root.path]?.count == 2)
    #expect(throws: StorageError.self) { try StorageCleanup.review(selection: [partial.files[0].id], scan: partial) }
}
