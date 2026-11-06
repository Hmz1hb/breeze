import Foundation

extension CleanupInventoryBuilder {
    func findAndroid() throws {
        let environment = ProcessInfo.processInfo.environment
        let userHome = environment["ANDROID_USER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? CleanupFiles.home.appendingPathComponent(".android")
        let avdRoot = (environment["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? userHome.appendingPathComponent("avd")).standardizedFileURL
        let sdk = (environment["ANDROID_HOME"].map { URL(fileURLWithPath: $0) }
            ?? environment["ANDROID_SDK_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? CleanupFiles.home.appendingPathComponent("Library/Android/sdk")).standardizedFileURL
        let processes = ["emulator", "qemu-system-aarch64", "qemu-system-x86_64", "sdkmanager"]
        var imageUsers: [String: [String]] = [:]

        // Read a bounded set of known configuration fields for descriptions only.
        // Metadata never supplies removal paths; devices stay under the AVD root.
        func configuration(_ url: URL) -> [String: String] {
            guard (try? CleanupFiles.validateLocation(url)) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isUbiquitousItemKey]),
                  values.isRegularFile == true, values.isUbiquitousItem != true,
                  let size = values.fileSize, size <= 131_072,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
            let fields: Set<String> = ["avd.ini.displayname", "image.sysdir.1", "abi.type", "hw.device.name"]
            return text.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
                let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, fields.contains(pair[0]) { result[pair[0]] = String(pair[1].prefix(500)) }
            }
        }

        do {
            for device in try children(avdRoot) where device.pathExtension == "avd" {
                try Task.checkCancellation()
                let config = configuration(device.appendingPathComponent("config.ini"))
                let name = config["avd.ini.displayname"] ?? device.deletingPathExtension().lastPathComponent
                if let image = config["image.sysdir.1"] {
                    let imageURL = image.hasPrefix("/") ? URL(fileURLWithPath: image) : sdk.appendingPathComponent(image)
                    imageUsers[imageURL.standardizedFileURL.path, default: []].append(name)
                }
                let registration = device.deletingPathExtension().appendingPathExtension("ini")
                let urls = [device] + (manager.fileExists(atPath: registration.path) ? [registration] : [])
                append(title: "Android · \(name)", urls: urls, category: .android, risk: .personal,
                    detail: "An Android virtual device with its registration, installed apps, snapshots and private test data. Consider removing devices you no longer need for current work. Missing last-use dates do not establish inactivity.",
                    recovery: "Restore both the device folder and its registration from Trash, or create a new device in Android Studio. A new device will not restore the old test data.",
                    ownerID: "com.google.android.studio", ownerName: "Android Studio", processes: processes,
                    context: .init(summary: [config["hw.device.name"], config["abi.type"]].compactMap { $0 }.joined(separator: " · "),
                        sections: [.init(title: "System image", text: config["image.sysdir.1"] ?? "Unknown"),
                                   .init(title: "Removal tradeoff", text: "You can recreate this device later, but its installed apps, snapshots and local app data are part of this removal.")]))
            }
        } catch is CancellationError { throw CancellationError() }
        catch { recordIssue(error, location: avdRoot.path) }

        let images = sdk.appendingPathComponent("system-images")
        func directories(_ root: URL) throws -> [URL] {
            try children(root).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        do {
            for platform in try directories(images) {
                for variant in try directories(platform) {
                    for image in try directories(variant) {
                        try Task.checkCancellation()
                        guard (try? image.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                        let users = imageUsers[image.standardizedFileURL.path] ?? []
                        append(title: "Android image · \(platform.lastPathComponent) · \(variant.lastPathComponent) · \(image.lastPathComponent)",
                            urls: [image], category: .android, risk: .review,
                            detail: "A downloaded Android emulator system image. Devices using it cannot start until the image is reinstalled. Device references are based only on configurations found in this scan.",
                            recovery: "Reinstall this exact API, variant and architecture through Android Studio's SDK Manager.",
                            ownerID: "com.google.android.studio", ownerName: "Android Studio", processes: processes,
                            context: .init(summary: users.isEmpty ? "No matching virtual device found in the scanned AVD folder" : "Used by: " + users.sorted().joined(separator: ", "),
                                sections: [.init(title: "Devices using this image", text: users.isEmpty ? "No matches found. Devices in other locations or unreadable configurations may still use this image." : users.sorted().joined(separator: "\n"))]))
                    }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { recordIssue(error, location: images.path) }
    }
}
