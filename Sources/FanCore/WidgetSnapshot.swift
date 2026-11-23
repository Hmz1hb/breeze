import Foundation

/// The small status file the app shares with its WidgetKit extension through their app group.
public struct WidgetSnapshot: Codable, Sendable {
    public var date = Date()
    public var status = "Waiting for sensors"
    public var temperature: Double?
    public var fanRPM: Double?
    public var fanCount = 0
    public var cpuPercent: Double?
    public var memoryPercent: Double?
    public var batteryPercent: Double?
    public var charging: String?
    public var diskFree: Int64?
    public var diskTotal: Int64?
    public init() {}

    /// scripts/build.sh writes the team-prefixed group into both Info.plists.
    public static var fileURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BreezeAppGroup") as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent("widget.json")
    }

    public static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
