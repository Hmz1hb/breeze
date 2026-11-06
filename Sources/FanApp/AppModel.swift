import AppKit
import CHardware
import FanCore
import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
    var snapshot: Snapshot?
    var systemStats: SystemStats?
    var readError: String?
    var message: String?
    var controllerMessage = "macOS manages cooling."
    var enabled = false
    var busy = false
    var manual = false
    var appliedPercent: Double?
    var activeMode: CoolingMode = .automatic
    var boosted = false
    var sleeping = false
    var configuration: CoolingConfiguration
    var resumeOnWake: Bool { didSet { preferences.set(resumeOnWake, forKey: "resumeOnWake") } }
    var applyAtLaunch: Bool { didSet { preferences.set(applyAtLaunch, forKey: "applyAtLaunch") } }
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var helperStatus = HelperService.service.status
    var history: [Sample] = []
    var historySeconds = 300
    var savedProfiles: [SavedCoolingProfile]
    var boostEndsAt: Date?
    var page = Page.overview
    var widgetPreferences: WidgetPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(widgetPreferences) {
                preferences.set(data, forKey: "menuWidget")
            }
        }
    }
    var widgetObservers = 0
    let widgetActivity = ActivityModel()
    let widgetStorage = StorageMonitor()
    let storage = StorageModel()
    let network = NetworkModel()
    let activity = ActivityModel()
    let macInfo = MacInfoModel()
    let battery = BatteryModel()
    private let monitor = Monitor()
    private let session: any CoolingSession
    private let preferences: UserDefaults
    private var loop: Task<Void, Never>?
    private var widgetLoop: Task<Void, Never>?
    private var widgetStorageLoop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var appliedConfiguration: CoolingConfiguration?
    enum Page: String, CaseIterable {
        case overview = "Overview", cooling = "Cooling", statistics = "Statistics", battery = "Battery", storage = "Storage", network = "Network", mac = "This Mac", settings = "Settings"
        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .cooling: "fanblades"
            case .statistics: "waveform.path.ecg"
            case .battery: "battery.100percent"
            case .storage: "internaldrive"
            case .network: "network"
            case .mac: "desktopcomputer"
            case .settings: "gearshape"
            }
        }
    }
    struct Sample: Identifiable {
        let id = UUID()
        let date: Date
        let temperature: Double
        let rpm: Double
        let cpu: Double?
    }

    init(defaults: UserDefaults = .standard, session: any CoolingSession = ControlSession()) {
        preferences = defaults
        widgetPreferences = WidgetPreferences.load(from: defaults.data(forKey: "menuWidget"))
        self.session = session
        if let data = defaults.data(forKey: "coolingProfile"),
           let saved = try? JSONDecoder().decode(CoolingConfiguration.self, from: data),
           (try? saved.validate()) != nil {
            configuration = saved
        } else { configuration = CoolingConfiguration() }
        resumeOnWake = defaults.object(forKey: "resumeOnWake") as? Bool ?? true
        applyAtLaunch = defaults.bool(forKey: "applyAtLaunch")
        savedProfiles = SavedCoolingProfile.load(from: defaults.data(forKey: "savedCoolingProfiles"))
    }
    var visibleHistory: [Sample] {
        // Compare seconds directly: the 27.2 SDK's back-deployed Date >= / <=
        // entry points can resolve to null on early macOS 27.2 runtimes.
        let cutoff = Date().timeIntervalSinceReferenceDate - Double(historySeconds)
        return history.filter { $0.date.timeIntervalSinceReferenceDate >= cutoff }
    }
    var boostRemaining: String? {
        guard let boostEndsAt else { return nil }
        let seconds = max(0, Int(ceil(boostEndsAt.timeIntervalSinceNow)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    func stage(_ preset: CoolingPreset) {
        configuration = preset.configuration(boostTemperature: configuration.boostTemperature)
    }
    @discardableResult func saveProfile(named name: String) -> Bool {
        do {
            let profile = try SavedCoolingProfile(name: name, configuration: configuration)
            guard savedProfiles.count < 24 else { throw FanError("You can save up to 24 profiles. Remove one to make room.") }
            guard !savedProfiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(profile.name) == .orderedSame }) else {
                throw FanError("A profile with that name already exists. Choose another name.")
            }
            savedProfiles.append(profile)
            persistProfiles()
            message = nil
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func deleteProfile(_ id: UUID) {
        savedProfiles.removeAll { $0.id == id }
        persistProfiles()
    }
    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(savedProfiles) { preferences.set(data, forKey: "savedCoolingProfiles") }
    }
    var rpmLabel: String {
        guard let fans = snapshot?.fans, !fans.isEmpty else { return "—" }
        return "\(Int(fans.map(\.current).max() ?? 0))"
    }
    var statusTitle: String {
        guard let snapshot else { return "Waiting for sensors" }
        if snapshot.fans.isEmpty { return "Passively cooled" }
        if sleeping { return "Sleeping" }
        if !enabled && snapshot.fans.contains(where: \.isManual) { return "External manual control" }
        if boosted { return "Heat boost · 100%" }
        if let appliedPercent, manual {
            if appliedPercent >= 99 { return "Maximum cooling" }
            return "\(activeMode.title) · \(Int(appliedPercent))%"
        }
        return "System cooling"
    }
    var statusDetail: String {
        if !enabled && snapshot?.fans.contains(where: \.isManual) == true { return "Another session is setting fan targets" }
        if snapshot == nil { return "Waiting for a live hardware reading" }
        return controllerMessage
    }
    func start() {
        guard loop == nil else { return }
        widgetStorageLoop = Task { [weak self, widgetStorage] in
            await widgetStorage.run(when: { [weak self] in
                guard let self, !self.sleeping else { return false }
                return self.widgetPreferences.needsStorageInMenuBar ||
                    (self.widgetObservers > 0 && self.widgetPreferences.needsStorageInPopover)
            })
        }
        widgetLoop = Task { [weak self, widgetActivity] in
            await widgetActivity.run(when: { [weak self] in
                guard let self, !self.sleeping else { return false }
                return self.widgetPreferences.needsActivityInMenuBar ||
                    (self.widgetObservers > 0 && self.widgetPreferences.needsActivityInPopover)
            }, includeProcesses: { [weak self] in
                guard let self else { return false }
                return self.widgetObservers > 0 && self.widgetPreferences.sections.contains(.processes)
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.didWake() }
        })
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                helperStatus = HelperService.service.status
                if !sleeping {
                    do {
                        let reading = try await monitor.read()
                        snapshot = reading.snapshot; systemStats = reading.stats; readError = nil
                        if let t = reading.snapshot.hottest {
                            history.append(Sample(date: Date(), temperature: t,
                                                  rpm: reading.snapshot.fans.map(\.current).max() ?? 0,
                                                  cpu: reading.stats?.cpuPercent))
                            let cutoff = Date().addingTimeInterval(-600)
                            history.removeAll { $0.date < cutoff }
                        }
                    } catch { readError = error.localizedDescription; snapshot = nil }
                    await finishExpiredBoost()
                    if enabled && !busy {
                        do { consume(try await session.request(Command(.heartbeat))) }
                        catch { disconnected(error) }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if applyAtLaunch { Task { await apply() } }
    }
    func enable() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do { try await connect() }
        catch { message = error.localizedDescription }
    }
    private func connect() async throws {
        do { try HelperService.prepare() }
        catch {
            helperStatus = HelperService.service.status
            page = .settings
            throw error
        }
        helperStatus = HelperService.service.status
        let reply = try await session.enable()
        enabled = true
        consume(reply)
    }
    func apply() async {
        if await applyConfiguration(configuration, persist: true) { boostEndsAt = nil }
    }
    @discardableResult private func applyConfiguration(_ requested: CoolingConfiguration, persist: Bool) async -> Bool {
        guard !busy else { return false }
        busy = true; message = nil
        defer { busy = false }
        do {
            // Returning control to macOS must work even while the editor has invalid draft values.
            var profile = requested.mode == .automatic ? CoolingConfiguration() : requested
            profile.mode = requested.mode
            profile.manualPercent = profile.manualPercent.rounded()
            profile.targetTemperature = profile.targetTemperature.rounded()
            try profile.validate()
            if !enabled { try await connect() }
            let reply = try await session.request(Command(.configure, configuration: profile))
            consume(reply)
            if reply.ok {
                appliedConfiguration = profile
                if persist, let data = try? JSONEncoder().encode(profile) { preferences.set(data, forKey: "coolingProfile") }
            }
            return reply.ok
        } catch { message = error.localizedDescription; return false }
    }
    func startTimedBoost(minutes: Int) async {
        guard [1, 5, 10, 15, 30].contains(minutes) else { return }
        var profile = configuration
        profile.mode = .manual
        profile.manualPercent = 100
        if await applyConfiguration(profile, persist: false) {
            boostEndsAt = Date().addingTimeInterval(Double(minutes * 60))
        }
    }
    func endTimedBoost() async {
        guard boostEndsAt != nil else { return }
        var profile = configuration
        profile.mode = .automatic
        // Keep the deadline on failure so the monitoring loop retries restoration.
        if await applyConfiguration(profile, persist: false) { boostEndsAt = nil }
    }
    func finishExpiredBoost(now: Date = .now) async {
        guard let boostEndsAt, boostEndsAt.timeIntervalSince(now) <= 0, !busy else { return }
        await endTimedBoost()
    }
    func maximum() async {
        guard !busy else { return }
        configuration.mode = .manual
        configuration.manualPercent = 100
        await apply()
    }
    func automatic() async {
        guard !busy else { return }
        configuration.mode = .automatic
        await apply()
    }
    private func consume(_ reply: Reply) {
        manual = reply.manual
        appliedPercent = reply.percent
        activeMode = reply.mode
        boosted = reply.boosted
        controllerMessage = reply.message
        if !reply.ok { message = reply.message }
    }
    private func disconnected(_ error: any Error) {
        if boostEndsAt != nil { appliedConfiguration = nil }
        boostEndsAt = nil
        enabled = false; manual = false; appliedPercent = nil; boosted = false; activeMode = .automatic
        message = error.localizedDescription
        controllerMessage = "Control connection lost. Check the live fan modes below."
    }
    private func willSleep() async {
        sleeping = true
        guard enabled else { return }
        do { consume(try await session.request(Command(.sleep))) }
        catch { disconnected(error) }
    }
    private func didWake() async {
        sleeping = false
        if let boostEndsAt, boostEndsAt.timeIntervalSinceNow <= 0 { await endTimedBoost(); return }
        guard resumeOnWake, let profile = appliedConfiguration, profile.mode != .automatic else {
            if boostEndsAt != nil { appliedConfiguration = nil }
            boostEndsAt = nil
            if enabled { do { consume(try await session.request(Command(.automatic))) } catch { disconnected(error) } }
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if enabled { consume(try await session.request(Command(.wake, configuration: profile))) }
            else {
                try await connect()
                consume(try await session.request(Command(.configure, configuration: profile)))
            }
        } catch { disconnected(error) }
    }
    func setLoginEnabled(_ value: Bool) async {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if value && !loginEnabled { message = "Approve Breeze in System Settings → General → Login Items." }
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; message = error.localizedDescription }
    }
    func setupHelper() {
        message = nil
        do { try HelperService.prepare() }
        catch { message = error.localizedDescription }
        helperStatus = HelperService.service.status
        if helperStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    func openHelperSettings() { SMAppService.openSystemSettingsLoginItems() }
    func removeHelper() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await disable()
        do { try await HelperService.service.unregister(); message = "Cooling helper removed. macOS manages cooling." }
        catch { message = error.localizedDescription }
        helperStatus = HelperService.service.status
    }
    func disable() async {
        if boostEndsAt != nil { appliedConfiguration = nil }
        boostEndsAt = nil
        await session.stop()
        enabled = false; manual = false; appliedPercent = nil; activeMode = .automatic; boosted = false
    }
    func quit() async {
        loop?.cancel()
        widgetLoop?.cancel()
        widgetStorageLoop?.cancel()
        await disable()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}
