import Foundation

/// A launchd job found in a LaunchAgents or LaunchDaemons folder. Read-only:
/// Breeze lists these for inspection and never edits, unloads or removes them.
public struct StartupItem: Identifiable, Sendable {
    public enum Scope: String, CaseIterable, Sendable {
        case user = "Your launch agents", agents = "Launch agents for all users", daemons = "Launch daemons"
    }

    public let id: String
    public let label: String
    public let program: String?
    public let scope: Scope
    public let runsAtLoad: Bool
    public let keepAlive: Bool
    public let disabled: Bool
    public var url: URL { URL(fileURLWithPath: id) }
}

public enum StartupItems {
    @concurrent public static func list() async -> [StartupItem] {
        let folders: [(URL, StartupItem.Scope)] = [
            (CleanupFiles.home.appendingPathComponent("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .agents),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemons)
        ]
        return folders.flatMap { folder, scope -> [StartupItem] in
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return urls.filter { $0.pathExtension == "plist" }.compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
                return item(plist, path: url.path, scope: scope)
            }
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func item(_ plist: [String: Any], path: String, scope: StartupItem.Scope) -> StartupItem? {
        guard let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        // KeepAlive may be a dictionary of conditions; any condition can relaunch the job.
        let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        return StartupItem(id: path, label: label, program: program, scope: scope,
                           runsAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                           disabled: plist["Disabled"] as? Bool ?? false)
    }
}
