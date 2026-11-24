import Foundation
import IOKit.hid
import Observation
import UserNotifications

struct DeviceBattery: Identifiable, Equatable, Sendable {
    struct Level: Equatable, Sendable {
        let label: String
        let percent: Int
    }
    let id: String
    let name: String
    let kind: String?
    let levels: [Level]

    var symbol: String {
        switch kind?.lowercased() ?? "" {
        case let value where value.contains("headphone") || value.contains("headset"): "airpodspro"
        case let value where value.contains("mouse") || value.contains("mx master") || value.contains("mx anywhere"): "magicmouse"
        case let value where value.contains("keyboard") || value.contains("mx keys"): "keyboard"
        case let value where value.contains("trackpad"): "rectangle.and.hand.point.up.left"
        case let value where value.contains("gamepad") || value.contains("game"): "gamecontroller"
        default: "dot.radiowaves.left.and.right"
        }
    }
    var lowest: Int? { levels.map(\.percent).min() }

    /// Parses `system_profiler -json SPBluetoothDataType`. Connected devices are single-key
    /// dictionaries whose `device_batteryLevel…` values look like "85%".
    static func parse(_ data: Data) -> [DeviceBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        return controllers.flatMap { controller -> [DeviceBattery] in
            let connected = controller["device_connected"] as? [[String: Any]] ?? []
            return connected.flatMap { entry in
                entry.compactMap { name, value -> DeviceBattery? in
                    guard let info = value as? [String: Any] else { return nil }
                    let levels = info.keys.filter { $0.hasPrefix("device_batteryLevel") }.sorted().compactMap { key -> Level? in
                        guard let text = info[key] as? String,
                              let percent = Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
                              (0...100).contains(percent) else { return nil }
                        let suffix = String(key.dropFirst("device_batteryLevel".count))
                        return Level(label: suffix == "Main" ? "" : suffix, percent: percent)
                    }
                    guard !levels.isEmpty else { return nil }
                    return DeviceBattery(id: info["device_address"] as? String ?? name, name: name,
                                         kind: info["device_minorType"] as? String, levels: levels)
                }
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @concurrent static func read() async -> [DeviceBattery]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-detailLevel", "basic", "-timeout", "8", "SPBluetoothDataType"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(data)
    }
}

@MainActor @Observable
final class DeviceBatteryModel {
    nonisolated static let accessNotification = "breeze.logitech-access"

    var devices: [DeviceBattery] = []
    var updated: Date?
    var failed = false
    /// Logitech devices Breeze could read once the user allows Input Monitoring.
    var needsAccess: [String] = []
    var accessDenied = false
    var accessDismissed: Bool {
        didSet { defaults.set(accessDismissed, forKey: "logitechAccessDismissed") }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accessDismissed = defaults.bool(forKey: "logitechAccessDismissed")
    }

    func refresh(announce: Bool = false) async {
        async let bluetooth = DeviceBattery.read()
        async let logitech = LogitechBattery.read()
        let (system, vendor) = await (bluetooth, logitech)
        guard !Task.isCancelled else { return }
        // HID++ covers Logitech devices macOS lists without a level; prefer it over a name match.
        let names = Set(vendor.batteries.map(\.name))
        let merged = (system ?? []).filter { !names.contains($0.name) } + vendor.batteries
        devices = merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        needsAccess = vendor.needsAccess.sorted()
        accessDenied = LogitechBattery.access == kIOHIDAccessTypeDenied
        failed = system == nil && vendor.batteries.isEmpty
        updated = .now
        if announce { await announceAccessOnce() }
    }

    /// The user asked for it: show the system prompt, then pick up the result.
    func requestAccess() {
        LogitechBattery.requestAccess()
        accessDismissed = false
        Task { await refresh() }
    }

    /// One notification ever, and only when notifications are already allowed: asking for
    /// notification permission here would just swap one surprise prompt for another.
    private func announceAccessOnce() async {
        guard let device = needsAccess.first, !accessDenied, !accessDismissed, AlertCenter.available,
              !defaults.bool(forKey: "logitechAccessAnnounced") else { return }
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized else { return }
        defaults.set(true, forKey: "logitechAccessAnnounced")
        let content = UNMutableNotificationContent()
        content.title = "Show your \(device) battery?"
        content.body = "Click to see why Breeze needs one macOS permission for this."
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.accessNotification, content: content, trigger: nil))
    }

    /// Polls once a minute only while a visible view needs device batteries.
    func run(when shouldRead: @MainActor () -> Bool, announce: @MainActor () -> Bool) async {
        while !Task.isCancelled {
            if shouldRead(), updated.map({ Date().timeIntervalSince($0) >= 60 }) ?? true { await refresh(announce: announce()) }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }
}
