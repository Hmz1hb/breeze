import Foundation
import StorageCore
import Testing
@testable import FanApp

private struct BrowserFixture {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("storage-browser-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("same contents".utf8).write(to: root.appendingPathComponent("nested/first.txt"))
        try Data("same contents".utf8).write(to: root.appendingPathComponent("nested/second.txt"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func trashUpdatesResultsWithoutLosingFolderOrFailedSelection() async throws {
    let fixture = try BrowserFixture(); defer { fixture.clean() }
    let scan = try await StorageScanner.scan(root: fixture.root)
    let model = StorageModel()
    model.scan = scan
    let nested = fixture.root.appendingPathComponent("nested")
    model.focus(nested)
    model.visibleRows = 200
    model.tab = .duplicates
    let first = try #require(scan.files.first { $0.url.lastPathComponent == "first.txt" })
    let second = try #require(scan.files.first { $0.url.lastPathComponent == "second.txt" })
    model.inspected = first
    model.selection = [first.id, second.id]
    model.applyMovedFiles([first.id])

    #expect(model.scan?.root == scan.root)
    #expect(model.focusedFolder == nested)
    #expect(model.tab == .duplicates)
    #expect(model.visibleRows == 200)
    #expect(model.nodes.map(\.id) == [second.id])
    #expect(model.scan?.files.count == 2)
    #expect(model.scan?.bytes == scan.bytes - first.bytes)
    #expect(model.scan?.duplicates.isEmpty == true)
    #expect(model.selection == [second.id])
    #expect(model.inspected == nil)
    #expect(model.file(first.id) == nil)
    #expect(model.file(second.id)?.id == second.id)

    model.inspected = second
    model.applyMovedFiles([])
    #expect(model.selection == [second.id])
    #expect(model.inspected?.id == second.id)

    model.applyMovedFiles([second.id])
    #expect(model.focusedFolder == nested)
    #expect(model.nodes.isEmpty)
    #expect(model.scan != nil)
    #expect(model.scan?.files.count == 1)
    model.focus(scan.root)
    #expect(model.nodes.first?.url.lastPathComponent == "outside.txt")
}

@Test @MainActor func removingLastScannedFileKeepsScanAndRootAvailable() async throws {
    let fixture = try BrowserFixture(); defer { fixture.clean() }
    let scan = try await StorageScanner.scan(root: fixture.root)
    let model = StorageModel()
    model.scan = scan
    model.focus(scan.root)
    model.applyMovedFiles(Set(scan.files.map(\.id)))
    #expect(model.scan?.root == scan.root)
    #expect(model.scan?.bytes == 0)
    #expect(model.scan?.files.isEmpty == true)
    #expect(model.focusedFolder == scan.root)
    #expect(model.nodes.isEmpty)
}
