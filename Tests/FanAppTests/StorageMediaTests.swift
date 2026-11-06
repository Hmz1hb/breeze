import AppKit
import AVFoundation
import CoreVideo
import QuickLookThumbnailing
import Testing
@testable import FanApp

@MainActor private final class ThumbnailBackendStub: StorageThumbnailBackend {
    var requests: [QLThumbnailGenerator.Request] = []
    var completions: [@MainActor (NSImage?) -> Void] = []
    var cancelled: [QLThumbnailGenerator.Request] = []
    func generate(_ request: QLThumbnailGenerator.Request, completion: @escaping @MainActor (NSImage?) -> Void) {
        requests.append(request); completions.append(completion)
    }
    func cancel(_ request: QLThumbnailGenerator.Request) { cancelled.append(request) }
}

@MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "StorageTests.Timeout", code: 1) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func thumbnailsBoundWorkCancelOffscreenRequestsAndReuseCache() async throws {
    let backend = ThumbnailBackendStub()
    let loader = StorageThumbnailLoader(backend: backend)
    let urls = (0..<6).map { URL(fileURLWithPath: "/thumbnail-test-\($0).png") }
    var tasks: [Task<NSImage?, Never>] = []
    for index in 0..<3 {
        tasks.append(Task { await loader.image(for: urls[index], scale: 2) })
        try await waitUntil { backend.requests.count == index + 1 }
    }
    for index in 3..<6 { tasks.append(Task { await loader.image(for: urls[index], scale: 2) }) }
    defer { tasks.forEach { $0.cancel() } }
    try await waitUntil { backend.requests.count == 3 }
    let activeIndex = 0
    tasks[activeIndex].cancel()
    try await waitUntil { backend.cancelled.count == 1 && backend.requests.count == 4 }
    #expect(await tasks[activeIndex].value == nil)
    let image = NSImage(size: NSSize(width: 44, height: 44))
    // A late completion from a cancelled request must not resume it a second time.
    backend.completions[0](image)
    backend.completions[1](image)
    try await waitUntil { backend.requests.count == 5 }
    backend.completions[2](image)
    try await waitUntil { backend.requests.count == 6 }
    for index in 3..<6 { backend.completions[index](image) }
    for (index, task) in tasks.enumerated() where index != activeIndex { #expect(await task.value != nil) }
    let cachedURL = urls[1]
    #expect(await loader.image(for: cachedURL, scale: 2) === image)
    #expect(backend.requests.count == 6)
    loader.clearCache()
    let reloaded = Task { await loader.image(for: cachedURL, scale: 2) }
    try await waitUntil { backend.requests.count == 7 }
    backend.completions[6](image)
    #expect(await reloaded.value === image)
}

@Test @MainActor func cancellingQueuedThumbnailNeverStartsGeneration() async throws {
    let backend = ThumbnailBackendStub()
    let loader = StorageThumbnailLoader(backend: backend)
    let active = (0..<3).map { index in Task { await loader.image(for: URL(fileURLWithPath: "/active-\(index)"), scale: 1) } }
    defer { active.forEach { $0.cancel() } }
    try await waitUntil { backend.requests.count == 3 }
    let queued = Task { await loader.image(for: URL(fileURLWithPath: "/queued"), scale: 1) }
    await Task.yield()
    queued.cancel()
    #expect(await queued.value == nil)
    backend.completions[0](nil)
    for _ in 0..<5 { await Task.yield() }
    #expect(backend.requests.count == 3)
}

/// A real local H.264 file exercises decoding, not just the isPlayable flag.
private func makeVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96
    ])
    writer.add(input)
    guard writer.startWriting() else { throw try #require(writer.error) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<90 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 2), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

@Test @MainActor func localMP4PlaysSeeksAndReleasesItsPlayer() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("breeze-playback-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try await makeVideo(at: url)
    let playback = StorageMediaPlayback()
    defer { playback.stop() }
    await playback.load(url)
    try await waitUntil { !playback.loading }
    #expect(playback.error == nil)
    #expect(playback.player.currentItem?.status == .readyToPlay)
    playback.player.play()
    try await waitUntil { playback.player.currentTime().seconds > 0.15 }
    playback.player.pause()
    let sought = await playback.player.seek(to: CMTime(seconds: 1.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    #expect(sought)
    #expect(abs(playback.player.currentTime().seconds - 1.5) < 0.1)
    playback.stop()
    #expect(playback.player.currentItem == nil)
    #expect(playback.player.rate == 0)
    #expect(!playback.loading)
}

@Test @MainActor func invalidMediaReportsFailureAndStopClearsIt() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("breeze-invalid-\(UUID().uuidString).mp4")
    try Data("not a video".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let playback = StorageMediaPlayback()
    await playback.load(url)
    #expect(playback.error != nil)
    #expect(!playback.loading)
    #expect(playback.player.currentItem == nil)
    playback.stop()
    #expect(playback.error == nil)
}
