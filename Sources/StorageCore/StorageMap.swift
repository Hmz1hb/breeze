import Foundation
import CoreGraphics

public struct StorageNode: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public var bytes: Int64
    public var count: Int
    public let isDirectory: Bool
    public var category: FileCategory
    private var largest: Int64

    /// Build once on the scanner's executor, rather than walking the entire scan
    /// every time the user opens a folder.
    public static func directoryIndex(root: URL, files: [StorageFile]) -> [String: [StorageNode]] {
        var folders: [String: [String: StorageNode]] = [:]
        let rootPath = root.path
        for file in files {
            var child = file.url
            var folder = child.deletingLastPathComponent()
            while folder.path == rootPath || folder.path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") {
                let key = child.path
                if var node = folders[folder.path]?[key] {
                    node.bytes += file.bytes
                    node.count += 1
                    if file.bytes > node.largest { node.category = file.category; node.largest = file.bytes }
                    folders[folder.path]?[key] = node
                } else {
                    folders[folder.path, default: [:]][key] = StorageNode(
                        url: child, bytes: file.bytes, count: 1, isDirectory: child != file.url,
                        category: file.category, largest: file.bytes)
                }
                if folder.path == rootPath { break }
                child = folder
                folder = folder.deletingLastPathComponent()
            }
        }
        return folders.mapValues { nodes in
            nodes.values.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        }
    }

    public static func children(of folder: URL, files: [StorageFile]) -> [StorageNode] {
        let prefix = folder.path == "/" ? "/" : folder.path + "/"
        var nodes: [String: StorageNode] = [:]
        for file in files where file.id.hasPrefix(prefix) {
            let relative = String(file.id.dropFirst(prefix.count))
            let parts = relative.split(separator: "/", maxSplits: 1)
            guard let name = parts.first else { continue }
            let key = String(name)
            if var node = nodes[key] {
                node.bytes += file.bytes; node.count += 1
                if file.bytes > node.largest { node.category = file.category; node.largest = file.bytes }
                nodes[key] = node
            } else {
                nodes[key] = StorageNode(url: folder.appendingPathComponent(key), bytes: file.bytes, count: 1,
                                         isDirectory: parts.count > 1, category: file.category, largest: file.bytes)
            }
        }
        return nodes.values.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }
}

public struct MapTile: Sendable {
    public let index: Int
    public let rect: CGRect
}

public enum StorageTreemap {
    /// Balanced spatial partitioning. Rectangles preserve file-size proportions exactly.
    public static func layout(weights: [Int64], in bounds: CGRect) -> [MapTile] {
        let items = weights.enumerated().filter { $0.element > 0 }.map { ($0.offset, Double($0.element)) }
        var tiles: [MapTile] = []
        func split(_ values: ArraySlice<(Int, Double)>, rect: CGRect) {
            guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return }
            if values.count == 1 {
                tiles.append(MapTile(index: values[values.startIndex].0, rect: rect)); return
            }
            let total = values.reduce(0) { $0 + $1.1 }
            var sum = 0.0
            var middle = values.startIndex
            while middle < values.endIndex - 1 {
                let next = sum + values[middle].1
                if middle > values.startIndex, abs(total / 2 - sum) < abs(total / 2 - next) { break }
                sum = next; middle += 1
            }
            let fraction = sum / total
            let first: CGRect
            let second: CGRect
            if rect.width >= rect.height {
                let width = rect.width * fraction
                first = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
                second = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
            } else {
                let height = rect.height * fraction
                first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
                second = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
            }
            split(values[..<middle], rect: first)
            split(values[middle...], rect: second)
        }
        split(items[...], rect: bounds)
        return tiles
    }
}
