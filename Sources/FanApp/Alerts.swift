import AppKit
import Network
import Observation
import StorageCore
import SwiftUI
import UserNotifications

enum DiskSpace {
    static func startup() -> (free: Int64, total: Int64)? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity, total > 0 else { return nil }
        return (free, Int64(total))
    }
}

struct AlertSettings: Codable, Equatable {
    var temperature = false
    var temperatureLimit: Double = 95
    var disk = false
    var diskLimitGB: Double = 20
    var batteryHeat = false
    var batteryLimit: Double = 40
    var ssdWear = false
    var ssdLifeLimit: Double = 20
    var offline = false
    var any: Bool { temperature || disk || batteryHeat || ssdWear || offline }
}

/// Local notifications for conditions worth interrupting for. Each alert fires once,
/// re-arms after its condition clears, and repeats at most every 30 minutes.
@MainActor @Observable
final class AlertCenter {
    var settings: AlertSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "alertSettings") }
            if settings.any && !oldValue.any { Task { await requestPermission() } }
            updatePathMonitor()
        }
    }
    var permissionDenied = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var firing: Set<String> = []
    @ObservationIgnored private var lastPosted: [String: Date] = [:]
    @ObservationIgnored private var hotSince: Date?
    @ObservationIgnored private var nextSlowCheck = Date.distantPast
    @ObservationIgnored private var nextSSDCheck = Date.distantPast
    @ObservationIgnored private var slowCheckRunning = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var offlineSince: Date?

    /// Notifications need a bundled app; `swift run` builds have no bundle identifier.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: "alertSettings").flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) } ?? AlertSettings()
        updatePathMonitor()
    }

    func requestPermission() async {
        guard Self.available else { permissionDenied = true; return }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        permissionDenied = !granted
    }

    func sendTest() {
        Task { await requestPermission() }
        deliver(key: "test", title: "Breeze alerts are on", body: "You’ll be notified here when something needs your attention.")
    }

    /// Called about once a second from the app's monitoring loop.
    func evaluate(hottest: Double?) async {
        guard settings.any else { return }
        if settings.temperature, let hottest, hottest >= settings.temperatureLimit {
            if hotSince == nil { hotSince = .now }
            if let hotSince, Date().timeIntervalSince(hotSince) >= 30 {
                post("temperature", title: "Your Mac is running hot",
                     body: "The hottest die sensor has stayed at \(Int(hottest))°C or above for 30 seconds. Check Statistics → Processes for heavy work.")
            }
        } else {
            hotSince = nil
            if (hottest ?? 0) < settings.temperatureLimit - 5 { firing.remove("temperature") }
        }
        if settings.offline, let offlineSince, Date().timeIntervalSince(offlineSince) >= 30 {
            post("offline", title: "Internet connection lost", body: "Your Mac has had no usable network path for 30 seconds.")
        }
        // Slow checks run beside the monitoring loop so diskutil can never delay the helper heartbeat.
        if !slowCheckRunning, nextSlowCheck.timeIntervalSinceNow <= 0 {
            nextSlowCheck = Date().addingTimeInterval(60)
            slowCheckRunning = true
            Task { await slowChecks(); slowCheckRunning = false }
        }
    }

    private func slowChecks() async {
        if settings.disk, let space = DiskSpace.startup() {
            let limit = Int64(settings.diskLimitGB * 1_000_000_000)
            if space.free < limit {
                post("disk", title: "Startup disk is almost full",
                     body: "\(ByteCountFormatter.string(fromByteCount: space.free, countStyle: .file)) available. Storage → Cleanup can help find space.")
            } else if space.free > limit + 2_000_000_000 { firing.remove("disk") }
        }
        if settings.batteryHeat {
            let battery = await BatteryReader.read()
            if let temperature = battery.temperature {
                if temperature >= settings.batteryLimit {
                    post("battery", title: "Battery is warm",
                         body: "The battery is at \(Int(temperature))°C. Heat speeds up battery wear; a charge limit with heat protection can help.")
                } else if temperature <= settings.batteryLimit - 3 { firing.remove("battery") }
            }
        }
        if settings.ssdWear, nextSSDCheck.timeIntervalSinceNow <= 0 {
            nextSSDCheck = Date().addingTimeInterval(6 * 3600)
            let drive = await StorageDriveReader.volumes().first(where: \.isStartup)
            if let life = drive?.health.lifeRemaining, Double(life) <= settings.ssdLifeLimit {
                post("ssd", title: "Startup SSD wear is high",
                     body: "The drive reports \(life)% estimated endurance remaining. Make sure your backups are current.")
            }
        }
    }

    private func post(_ key: String, title: String, body: String) {
        guard !firing.contains(key) else { return }
        if let last = lastPosted[key], Date().timeIntervalSince(last) < 1800 { return }
        firing.insert(key); lastPosted[key] = .now
        deliver(key: key, title: title, body: body)
    }

    private func deliver(key: String, title: String, body: String) {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "breeze.\(key).\(UUID().uuidString)", content: content, trigger: nil))
    }

    private func updatePathMonitor() {
        guard settings.offline else {
            pathMonitor?.cancel(); pathMonitor = nil; offlineSince = nil; firing.remove("offline")
            return
        }
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(online: online) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func pathChanged(online: Bool) {
        if online {
            if firing.contains("offline") {
                firing.remove("offline")
                deliver(key: "online", title: "Back online", body: "Your Mac’s network connection has been restored.")
            }
            offlineSince = nil
        } else if offlineSince == nil {
            offlineSince = .now
        }
    }
}

struct AlertSettingsView: View {
    @Bindable var alerts: AlertCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Alerts").font(.headline)
                Spacer()
                Button("Send test alert") { alerts.sendTest() }.disabled(!AlertCenter.available)
            }
            Text("Breeze sends a notification once when a condition starts, then waits for it to clear. Checks run on this Mac while Breeze is open.")
                .font(.caption).foregroundStyle(.secondary)
            rule("Die temperature stays above", isOn: $alerts.settings.temperature,
                 value: $alerts.settings.temperatureLimit, range: 80...105, step: 1, unit: "°C")
            rule("Startup disk has less than", isOn: $alerts.settings.disk,
                 value: $alerts.settings.diskLimitGB, range: 5...200, step: 5, unit: " GB free")
            rule("Battery temperature reaches", isOn: $alerts.settings.batteryHeat,
                 value: $alerts.settings.batteryLimit, range: 35...50, step: 1, unit: "°C")
            rule("SSD endurance remaining falls to", isOn: $alerts.settings.ssdWear,
                 value: $alerts.settings.ssdLifeLimit, range: 5...50, step: 5, unit: "%")
            Toggle("Internet connection is lost for 30 seconds", isOn: $alerts.settings.offline)
            if alerts.permissionDenied {
                HStack {
                    Label("Notifications are off for Breeze.", systemImage: "bell.slash").font(.caption).foregroundStyle(.orange)
                    Button("Open Notification Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }.controlSize(.small)
                }
            }
            if !AlertCenter.available {
                Text("Alerts need the packaged Breeze.app.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rule(_ title: String, isOn: Binding<Bool>, value: Binding<Double>, range: ClosedRange<Double>,
                      step: Double, unit: String) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            Stepper("\(Int(value.wrappedValue))\(unit)", value: value, in: range, step: step).fixedSize().disabled(!isOn.wrappedValue)
        }
    }
}
