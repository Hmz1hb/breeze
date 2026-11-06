import AppKit
import QuickLookThumbnailing

@MainActor protocol StorageThumbnailBackend {
    func generate(_ request: QLThumbnailGenerator.Request, completion: @escaping @MainActor (NSImage?) -> Void)
    func cancel(_ request: QLThumbnailGenerator.Request)
}

@MainActor private struct QuickLookThumbnailBackend: StorageThumbnailBackend {
    func generate(_ request: QLThumbnailGenerator.Request, completion: @escaping @MainActor (NSImage?) -> Void) {
        Task { @MainActor in
            let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            completion(result?.nsImage)
        }
    }
    func cancel(_ request: QLThumbnailGenerator.Request) { QLThumbnailGenerator.shared.cancel(request) }
}

/// One bounded queue for all storage rows. View disappearance cancels the actual
/// Quick Look request, rather than waiting for generation to finish first.
@MainActor
final class StorageThumbnailLoader {
    static let shared = StorageThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()
    private let backend: any StorageThumbnailBackend
    private var generation = 0
    private struct Job {
        let key: NSString
        let request: QLThumbnailGenerator.Request
        let continuation: CheckedContinuation<NSImage?, Never>
        let cost: Int
    }
    private var jobs: [UUID: Job] = [:]
    private var pending: [UUID] = []
    private var active: Set<UUID> = []
    private let concurrencyLimit = 3

    init(backend: (any StorageThumbnailBackend)? = nil) {
        self.backend = backend ?? QuickLookThumbnailBackend()
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1_024 * 1_024
    }

    func clearCache() { generation += 1; cache.removeAllObjects() }

    func image(for url: URL, scale: CGFloat) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(generation):\(scale):\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 44, height: 44),
                                                          scale: scale, representationTypes: .all)
                jobs[id] = Job(key: key, request: request, continuation: continuation,
                               cost: Int(44 * 44 * scale * scale * 4))
                pending.append(id)
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func pump() {
        while active.count < concurrencyLimit, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let job = jobs[id] else { continue }
            if let cached = cache.object(forKey: job.key) {
                jobs.removeValue(forKey: id)?.continuation.resume(returning: cached)
                continue
            }
            active.insert(id)
            backend.generate(job.request) { [weak self] image in
                self?.finish(id, image: image)
            }
        }
    }

    private func finish(_ id: UUID, image: NSImage?) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        active.remove(id)
        // Cache failures too; unsupported files keep a cheap generic icon.
        let result = image ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        if let result { cache.setObject(result, forKey: job.key, cost: job.cost) }
        job.continuation.resume(returning: result)
        pump()
    }

    private func cancel(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        pending.removeAll { $0 == id }
        if active.remove(id) != nil { backend.cancel(job.request) }
        job.continuation.resume(returning: nil)
        pump()
    }
}
