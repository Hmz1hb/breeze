import Foundation

/// Best-effort descriptions only. Metadata never supplies cleanup paths or delete identifiers.
struct CleanupXcodeMetadata: Sendable {
    private var modelNames: [String: String] = [:]
    private var typeNames: [String: String] = [:]
    private var projectsByBundleID: [String: Set<String>] = [:]
    private var projectIndexComplete = true

    init() throws {
        // Installed profiles keep the model names current without a hard-coded device table.
        let profiles = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")
        for deviceType in Self.children(profiles) ?? [] where deviceType.pathExtension == "simdevicetype" {
            try Task.checkCancellation()
            let info = Self.plist(deviceType.appendingPathComponent("Contents/Info.plist"))
            let profile = Self.plist(deviceType.appendingPathComponent("Contents/Resources/profile.plist"))
            let name = info?["CFBundleName"] as? String ?? deviceType.deletingPathExtension().lastPathComponent
            if let id = info?["CFBundleIdentifier"] as? String { typeNames[id] = name }
            var models = profile?["representedModelIdentifiers"] as? [String] ?? []
            if let model = profile?["modelIdentifier"] as? String { models.append(model) }
            for model in models { modelNames[model] = name }
        }

        let derivedData = CleanupFiles.home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let builds = Self.children(derivedData)
        projectIndexComplete = builds != nil || !FileManager.default.fileExists(atPath: derivedData.path)
        for build in (builds ?? []).prefix(2_000) {
            try Task.checkCancellation()
            guard let project = Self.workspace(build) else { continue }
            let products = build.appendingPathComponent("Build/Products")
            guard let configurations = Self.children(products) else {
                if FileManager.default.fileExists(atPath: products.path) { projectIndexComplete = false }
                continue
            }
            for configuration in configurations.prefix(100) where configuration.lastPathComponent.hasSuffix("simulator") {
                guard let apps = Self.children(configuration) else { projectIndexComplete = false; continue }
                for app in apps.prefix(500) where app.pathExtension == "app" {
                    try Task.checkCancellation()
                    guard let id = Self.plist(app.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String else {
                        projectIndexComplete = false
                        continue
                    }
                    projectsByBundleID[id, default: []].insert(project)
                }
                if apps.count > 500 { projectIndexComplete = false }
            }
            if configurations.count > 100 { projectIndexComplete = false }
        }
        if (builds?.count ?? 0) > 2_000 { projectIndexComplete = false }
    }

    static func children(_ url: URL) -> [URL]? {
        guard url.resolvingSymlinksInPath().path == url.path,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey]),
              values.isDirectory == true, values.isUbiquitousItem != true else { return nil }
        return try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]).sorted { $0.path < $1.path }
    }

    static func plist(_ url: URL) -> [String: Any]? {
        guard url.resolvingSymlinksInPath().path == url.path,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isUbiquitousItemKey]),
              values.isRegularFile == true, values.isUbiquitousItem != true,
              let size = values.fileSize, size <= 2_000_000,
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return value as? [String: Any]
    }

    static func workspace(_ build: URL) -> String? {
        guard let path = plist(build.appendingPathComponent("info.plist"))?["WorkspacePath"] as? String,
              path.hasPrefix("/"), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return path
    }

    func deviceName(_ raw: String) -> String {
        guard let range = raw.range(of: #"(?:iPhone|iPad|iPod|Watch|AppleTV|RealityDevice)\d+,\d+"#,
                                    options: .regularExpression),
              let name = modelNames[String(raw[range])] else { return raw }
        return raw.replacingCharacters(in: range, with: name)
    }

    static func runtimeName(_ identifier: String) -> String {
        let raw = identifier.components(separatedBy: ".SimRuntime.").last ?? identifier
        let parts = raw.split(separator: "-")
        guard let platform = parts.first, parts.count > 1,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return raw }
        return "\(platform == "xrOS" ? "visionOS" : String(platform)) \(parts.dropFirst().joined(separator: "."))"
    }

    func catalogItem(_ url: URL, rule: CleanupRule) -> (title: String, context: CleanupContext?) {
        let raw = url.lastPathComponent
        switch rule.path {
        case "Library/Developer/Xcode/iOS DeviceSupport":
            let name = deviceName(raw)
            return ("\(rule.title) · \(name)", CleanupContext(summary: "Connected-device debugging support · \(name)", sections: [
                .init(title: "Device support", text: "\(name)\nOriginal identifier: \(raw)"),
                .init(title: "Used by projects", text: "Shared by projects debugging this device and iOS version. This is support data for a physical device, not a simulator; Xcode does not record a project owner here.")
            ]))
        case "Library/Developer/Xcode/DerivedData":
            guard let project = Self.workspace(url) else { return ("\(rule.title) · \(raw)", nil) }
            let name = URL(fileURLWithPath: project).deletingPathExtension().lastPathComponent
            return ("\(rule.title) · \(name)", CleanupContext(summary: "Project: \(name)", sections: [
                .init(title: "Project or workspace", text: project)
            ]))
        default:
            return (rule.children ? "\(rule.title) · \(raw)" : rule.title, nil)
        }
    }

    func simulator(_ device: [String: Any], root: URL) throws -> (title: String, context: CleanupContext) {
        let rawName = device["name"] as? String ?? "Simulator"
        let typeID = device["deviceTypeIdentifier"] as? String
        let model = typeID.flatMap { typeNames[$0] }
        let name = deviceName(rawName)
        let runtime = device["runtimeName"] as? String ?? Self.runtimeName(device["runtime"] as? String ?? "Unknown OS")
        let state = device["state"] as? String ?? "Unknown state"
        let applications = root.appendingPathComponent("data/Containers/Bundle/Application")
        let containers = Self.children(applications)
        var complete = containers != nil
        var apps: [String: String] = [:]
        for container in (containers ?? []).prefix(2_000) {
            try Task.checkCancellation()
            guard let bundles = Self.children(container) else { complete = false; continue }
            for app in bundles where app.pathExtension == "app" {
                guard let info = Self.plist(app.appendingPathComponent("Info.plist")),
                      let id = info["CFBundleIdentifier"] as? String else { complete = false; continue }
                apps[id] = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
            }
        }
        if (containers?.count ?? 0) > 2_000 { complete = false }
        let projects = Set(apps.keys.flatMap { projectsByBundleID[$0] ?? [] }).sorted()
        let appNames = apps.values.sorted()
        let projectNames = projects.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let relation: String
        if !projectNames.isEmpty { relation = "Related projects: " + projectNames.joined(separator: ", ") }
        else if !appNames.isEmpty { relation = "Apps: " + appNames.joined(separator: ", ") }
        else { relation = complete ? "No installed apps found" : "Installed app information unavailable" }
        var sections: [CleanupContextSection] = [
            .init(title: "Simulated device", text: model.map { $0 == name ? name : "\(name) · \($0)" } ?? name),
            .init(title: "Operating system & status", text: "\(runtime) · \(state)\(device["isAvailable"] as? Bool == false ? " · runtime unavailable" : "")"),
            .init(title: "Related projects", text: projects.isEmpty
                  ? "No project match found in local Xcode build metadata. A simulator can be shared by several projects."
                  : projects.joined(separator: "\n") + "\nMatched by installed app bundle identifiers in Xcode build products. These are possible associations; the simulator may be shared with other projects."),
            .init(title: "Installed apps", text: apps.isEmpty
                  ? (complete ? "No user-installed apps found." : "App metadata is unavailable or has not been created yet.")
                  : apps.sorted { $0.key < $1.key }.map { "\($0.value) · \($0.key)" }.joined(separator: "\n"))
        ]
        if !complete || !projectIndexComplete {
            sections.append(.init(title: "Metadata availability", text: "Some app or project metadata could not be read or exceeded the scan limit. The lists may be incomplete."))
        }
        sections.append(.init(title: "Simulator identifier", text: device["udid"] as? String ?? "Unavailable"))
        return ("\(name) · \(runtime)", CleanupContext(summary: "\(state) · \(relation)", sections: sections))
    }
}
