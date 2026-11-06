import Foundation

struct CleanupToolInventory: Sendable {
    var entries: [CleanupEntry] = []
    var issues: [String] = []
}

enum CleanupTools {
    static var dockerExecutable: String? {
        ["/Applications/Docker.app/Contents/Resources/bin/docker", "/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StorageError("The cleanup tool returned an unsupported inventory format.")
        }
        return value
    }

    static func rows(_ data: Data) throws -> [[String: Any]] {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return array }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        return try lines.map { try object(Data($0.utf8)) }
    }

    static func entry(id: String, title: String, category: CleanupCategory, risk: CleanupRisk,
                      detail: String, recovery: String, action: CleanupAction, bytes: Int64,
                      resources: [CleanupResource] = [], blocked: String? = nil,
                      context: CleanupContext? = nil) -> CleanupEntry {
        CleanupEntry(id: id, title: title, category: category, risk: risk, detail: detail, recovery: recovery,
                     resources: resources, action: action, estimatedBytes: bytes, ownerID: nil, ownerName: nil,
                     blockedReason: blocked, lastUsed: nil, processes: [], modelRegistry: nil, context: context)
    }

    static func simulatorDevices() async throws -> [[String: Any]] {
        let result = try await CleanupCommand.run("/usr/bin/xcrun", ["simctl", "list", "--json"])
        let report = try object(result.checked())
        guard let devices = report["devices"] as? [String: [[String: Any]]] else { throw StorageError("Cannot read Xcode simulator devices.") }
        let runtimes = report["runtimes"] as? [[String: Any]] ?? []
        return devices.flatMap { runtime, values in values.map { value in
            let metadata = runtimes.first { $0["identifier"] as? String == runtime }
            var row = value
            row["runtime"] = runtime
            row["runtimeName"] = metadata?["name"]
            row["runtimeBuild"] = metadata?["buildversion"]
            return row
        } }
    }

    static func runtimeImages() async throws -> [String: [String: Any]] {
        let result = try await CleanupCommand.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "--json"])
        let report = try object(result.checked())
        // simctl's runtime image registry uses UUID keys. Do not infer delete
        // targets from runtime bundle paths or identifiers from a different registry.
        guard report.keys.allSatisfy({ UUID(uuidString: $0) != nil }),
              let images = report as? [String: [String: Any]] else {
            throw StorageError("Runtime images are not available in a supported format. Manage runtimes in Xcode Settings → Components.")
        }
        return images
    }

    static func simulators(metadata: CleanupXcodeMetadata) async throws -> CleanupToolInventory {
        var result = CleanupToolInventory()
        do {
            let devices = try await simulatorDevices()
            let running = await CleanupRunningApps.identifiers()
            let busy = running.contains("com.apple.iphonesimulator") || running.contains("com.apple.dt.Xcode")
            var contexts: [String: CleanupContext] = [:]
            for device in devices {
                try Task.checkCancellation()
                guard let id = device["udid"] as? String, UUID(uuidString: id) != nil,
                      let name = device["name"] as? String else { continue }
                let root = CleanupFiles.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(id)")
                let description = try metadata.simulator(device, root: root)
                contexts[id] = description.context
                let blocked = device["state"] as? String != "Shutdown" || busy
                    ? "Shut down this simulator, quit Simulator and Xcode, then rescan." : nil
                let footprint: [CleanupResource]
                // Xcode being open does not make a shut-down device's footprint
                // disappear from analysis. Removal still requires resolving blockers.
                do { footprint = [try CleanupFiles.snapshot(root)] }
                catch is CancellationError { throw CancellationError() }
                catch {
                    result.issues.append("\(name): \(error.localizedDescription)")
                    if blocked == nil { continue }
                    footprint = []
                }
                result.entries.append(entry(id: "simulator:\(id)", title: description.title, category: .xcode, risk: .personal,
                    detail: "A virtual device running \(CleanupXcodeMetadata.runtimeName(device["runtime"] as? String ?? "an unknown OS")). Includes simulated apps, photos, accounts and test data.",
                    recovery: "Create a new simulator in Xcode. Its previous app data cannot be restored by Breeze.",
                    action: .simulator(id), bytes: 0, resources: footprint, blocked: blocked, context: description.context))
            }
            do {
                let images = try await runtimeImages()
                let anyBooted = devices.contains { $0["state"] as? String != "Shutdown" }
                for (id, image) in images {
                    guard let build = image["build"] as? String, !build.isEmpty else { continue }
                    let identifier = image["runtimeIdentifier"] as? String ?? image["identifier"] as? String ?? "Simulator runtime"
                    let matchingBuild = devices.first { $0["runtimeBuild"] as? String == build }
                    let name = matchingBuild?["runtimeName"] as? String ?? CleanupXcodeMetadata.runtimeName(identifier)
                    let related = devices.filter { device in
                        let runtime = device["runtime"] as? String
                        if let runtimeBuild = device["runtimeBuild"] as? String { return runtimeBuild == build }
                        return runtime == identifier || (runtime.map(CleanupXcodeMetadata.runtimeName) == name)
                    }
                    let deviceNames = related.compactMap { device -> String? in
                        guard let raw = device["name"] as? String else { return nil }
                        return metadata.deviceName(raw)
                    }.sorted()
                    let projectSections = related.compactMap { device -> CleanupContextSection? in
                        guard let deviceID = device["udid"] as? String,
                              let section = contexts[deviceID]?.sections.first(where: { $0.title == "Related projects" }) else { return nil }
                        let deviceName = metadata.deviceName(device["name"] as? String ?? "Simulator")
                        return .init(title: "Projects related to \(deviceName)", text: section.text)
                    }
                    let context = CleanupContext(
                        summary: deviceNames.isEmpty ? "Shared simulator OS · no matching devices found" : "Used by: " + deviceNames.joined(separator: ", "),
                        sections: [.init(title: "Devices using this runtime", text: deviceNames.isEmpty ? "No matching simulator devices found." : deviceNames.joined(separator: "\n"))]
                            + projectSections + [.init(title: "Runtime identifier", text: identifier)])
                    let size = (image["sizeBytes"] as? NSNumber)?.int64Value ?? (image["size"] as? NSNumber)?.int64Value ?? 0
                    let blocked = busy || anyBooted ? "Shut down all simulators, quit Simulator and Xcode, then rescan." : nil
                    result.entries.append(entry(id: "runtime:\(id)", title: "\(name) · \(build)", category: .xcode, risk: .review,
                        detail: "A simulator runtime image managed by Xcode. Removing it prevents devices using this runtime from starting until it is reinstalled. Disk space recovery depends on macOS snapshots and runtime management.",
                        recovery: "Download the runtime again in Xcode Settings → Components.", action: .simulatorRuntime(id: id, build: build), bytes: max(0, size), blocked: blocked, context: context))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.issues.append("Simulator runtimes: \(error.localizedDescription)") }
        } catch is CancellationError { throw CancellationError() }
        catch { result.issues.append("Xcode simulators unavailable: \(error.localizedDescription)") }
        return result
    }

    static func dockerData(_ executable: String, context: String, arguments: [String]) async throws -> Data {
        let result = try await CleanupCommand.run(executable, ["--context", context] + arguments)
        return try result.checked()
    }

    static func dockerEndpoint(_ executable: String, context: String) async throws -> String {
        let data = try await dockerData(executable, context: context,
            arguments: ["context", "inspect", context, "--format", "{{json .Endpoints.docker.Host}}"])
        guard let host = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String,
              host.hasPrefix("unix:///"), !host.dropFirst(7).contains("\n") else {
            throw StorageError("Only local Docker contexts using a Unix socket are supported. Remote engines are never cleaned.")
        }
        return host
    }

    static func validateBuilder(_ executable: String, context: String, endpoint: String, builder: String) async throws {
        let data = try await dockerData(executable, context: context, arguments: ["buildx", "inspect", builder])
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        func values(_ key: String) -> [String] {
            lines.filter { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        guard values("Driver") == ["docker"], !values("Endpoint").isEmpty,
              values("Endpoint").allSatisfy({ $0 == context || $0 == endpoint }) else {
            throw StorageError("Build-cache cleanup is limited to this context's local Docker driver. Remote and custom builders are excluded.")
        }
    }

    static func docker() async throws -> CleanupToolInventory {
        guard let executable = dockerExecutable else { return CleanupToolInventory(issues: ["Docker CLI not installed; Docker cleanup was skipped."]) }
        var result = CleanupToolInventory()
        do {
            let current = try await CleanupCommand.run(executable, ["context", "show"])
            let context = String(decoding: try current.checked(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !context.isEmpty, context.count < 256, context.allSatisfy({ $0.isLetter || $0.isNumber || "_.-".contains($0) }) else {
                throw StorageError("Unsupported Docker context name.")
            }
            let endpoint = try await dockerEndpoint(executable, context: context)
            let data = try await dockerData(executable, context: context,
                arguments: ["image", "ls", "--all", "--no-trunc", "--format", "{{json .}}"])
            var seen: Set<String> = []
            for image in try rows(data) {
                guard let id = image["ID"] as? String, validImageID(id), seen.insert(id).inserted else { continue }
                let repository = image["Repository"] as? String ?? "<none>"
                let tag = image["Tag"] as? String ?? "<none>"
                result.entries.append(entry(id: "docker:\(context):\(id)", title: "\(repository):\(tag)", category: .docker, risk: .review,
                    detail: "Docker image \(id) in local context \(context). Size includes shared layers and is an upper estimate. Removal is refused if containers or multiple tags still need it; Breeze never forces removal, deletes containers or touches volumes.",
                    recovery: "Pull or rebuild the image. A local-only image may not be reproducible.",
                    action: .dockerImage(context: context, endpoint: endpoint, id: id), bytes: parseSize(image["Size"] as? String ?? "")))
            }
            do {
                // Use the context's built-in builder, explicitly pinned for both
                // inventory and removal. Never inherit a selected remote builder.
                try await validateBuilder(executable, context: context, endpoint: endpoint, builder: context)
                let cacheData = try await dockerData(executable, context: context,
                    arguments: ["buildx", "--builder", context, "du", "--format", "json"])
                for cache in try rows(cacheData) {
                    guard let id = cache["ID"] as? String, validCacheID(id),
                          cache["Reclaimable"] as? Bool == true, cache["Mutable"] as? Bool != true else { continue }
                    let size = (cache["Size"] as? NSNumber)?.int64Value ?? parseSize(cache["Size"] as? String ?? "")
                    result.entries.append(entry(id: "docker-cache:\(context):\(id)", title: "Build cache · \(id)", category: .docker, risk: .review,
                        detail: "\(cache["Description"] as? String ?? "BuildKit record"). Only this immutable, reclaimable record is targeted. Shared layers may remain; size is an upper estimate.",
                        recovery: "Rebuilt when the Docker build needs this layer again.",
                        action: .dockerBuildCache(context: context, endpoint: endpoint, builder: context, id: id), bytes: max(0, size)))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.issues.append("Docker build cache: \(error.localizedDescription)") }
        } catch is CancellationError { throw CancellationError() }
        catch {
            result.issues.append("Docker cleanup skipped. Check that your local Docker engine is running and the current Docker context is correct, then rescan. Details: \(error.localizedDescription)")
        }
        return result
    }

    static func validImageID(_ id: String) -> Bool {
        id.hasPrefix("sha256:") && id.count == 71 && id.dropFirst(7).allSatisfy(\.isHexDigit)
    }

    static func validCacheID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func parseSize(_ value: String) -> Int64 {
        let clean = value.replacingOccurrences(of: " ", with: "")
        let number = clean.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(number), amount.isFinite, amount >= 0 else { return 0 }
        let unit = String(clean.dropFirst(number.count)).uppercased()
        let factors: [String: Double] = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
                                       "KIB": 1024, "MIB": 1_048_576, "GIB": 1_073_741_824, "TIB": 1_099_511_627_776]
        let bytes = amount * (factors[unit] ?? 1)
        return bytes < Double(Int64.max) ? Int64(bytes) : 0
    }

    static func remove(_ entry: CleanupEntry) async throws {
        switch entry.action {
        case .trash: return
        case .simulator(let id):
            guard UUID(uuidString: id) != nil else { throw StorageError("Invalid simulator identifier.") }
            let devices = try await simulatorDevices()
            guard devices.contains(where: { $0["udid"] as? String == id && $0["state"] as? String == "Shutdown" }) else {
                throw StorageError("The simulator changed or is running. Shut it down and scan again.")
            }
            for resource in entry.resources { try CleanupFiles.validate(resource) }
            let result = try await CleanupCommand.run("/usr/bin/xcrun", ["simctl", "delete", id], timeout: 90)
            _ = try result.checked()
        case .simulatorRuntime(let id, let build):
            guard UUID(uuidString: id) != nil else { throw StorageError("Invalid simulator runtime identifier.") }
            let devices = try await simulatorDevices()
            guard devices.allSatisfy({ $0["state"] as? String == "Shutdown" }) else { throw StorageError("Shut down all simulators before deleting a runtime.") }
            let images = try await runtimeImages()
            guard images[id]?["build"] as? String == build else { throw StorageError("The runtime changed. Scan again.") }
            let result = try await CleanupCommand.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", id], timeout: 90)
            _ = try result.checked()
        case .dockerImage(let context, let endpoint, let id):
            guard let executable = dockerExecutable, validImageID(id),
                  try await dockerEndpoint(executable, context: context) == endpoint else { throw StorageError("The Docker context changed. Scan again.") }
            _ = try await dockerData(executable, context: context, arguments: ["image", "rm", "--no-prune", id])
        case .dockerBuildCache(let context, let endpoint, let builder, let id):
            guard let executable = dockerExecutable, validCacheID(id),
                  try await dockerEndpoint(executable, context: context) == endpoint else { throw StorageError("The Docker context changed. Scan again.") }
            try await validateBuilder(executable, context: context, endpoint: endpoint, builder: builder)
            let data = try await dockerData(executable, context: context, arguments: ["buildx", "--builder", builder, "du", "--format", "json"])
            guard try rows(data).contains(where: { $0["ID"] as? String == id && $0["Reclaimable"] as? Bool == true && $0["Mutable"] as? Bool != true }) else {
                throw StorageError("This build cache record changed or is in use. Scan again.")
            }
            _ = try await dockerData(executable, context: context,
                arguments: ["buildx", "--builder", builder, "prune", "--force", "--filter", "id=\(id)"])
        }
    }
}
