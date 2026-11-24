import AppKit
import FanCore
import IOKit.ps
import SwiftUI
import UniformTypeIdentifiers

/// A rule that applies a cooling profile while its trigger holds. The first matching rule wins;
/// when none match, Breeze returns to the last profile you applied yourself.
struct AutomationRule: Codable, Identifiable, Equatable {
    enum Trigger: Codable, Equatable {
        case app(bundleID: String, name: String)
        case battery
        case adapter
        /// Minutes after midnight. A start later than the end wraps past midnight.
        case schedule(start: Int, end: Int)
    }
    var id = UUID()
    var trigger: Trigger
    var profileName: String
    var configuration: CoolingConfiguration

    var title: String {
        switch trigger {
        case .app(_, let name): "While \(name) is open"
        case .battery: "On battery power"
        case .adapter: "On the power adapter"
        case .schedule(let start, let end): "From \(Self.clock(start)) to \(Self.clock(end))"
        }
    }
    var symbol: String {
        switch trigger {
        case .app: "app.badge"
        case .battery: "battery.50percent"
        case .adapter: "powerplug"
        case .schedule: "clock"
        }
    }

    func matches(runningApps: Set<String>, onBattery: Bool?, minute: Int) -> Bool {
        switch trigger {
        case .app(let bundleID, _): runningApps.contains(bundleID)
        case .battery: onBattery == true
        case .adapter: onBattery == false
        case .schedule(let start, let end):
            start == end ? false : start < end ? (start..<end).contains(minute) : minute >= start || minute < end
        }
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    static func load(from data: Data?) -> [Self] {
        guard let data, let rules = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return Array(rules.filter { (try? $0.configuration.validate()) != nil || $0.configuration.mode == .automatic }.prefix(24))
    }

    static var onBattery: Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

struct AutomationProfileChoice: Identifiable {
    let id: String
    let configuration: CoolingConfiguration
}

extension AppModel {
    var automationChoices: [AutomationProfileChoice] {
        var automatic = CoolingConfiguration(); automatic.mode = .automatic
        var maximum = CoolingConfiguration(); maximum.mode = .manual; maximum.manualPercent = 100
        maximum.boostTemperature = configuration.boostTemperature
        return [AutomationProfileChoice(id: "Automatic", configuration: automatic)]
            + CoolingPreset.allCases.map { AutomationProfileChoice(id: $0.rawValue, configuration: $0.configuration(boostTemperature: configuration.boostTemperature)) }
            + [AutomationProfileChoice(id: "Maximum cooling", configuration: maximum)]
            + savedProfiles.filter { !["Automatic", "Maximum cooling"].contains($0.name) && CoolingPreset(rawValue: $0.name) == nil }
                .map { AutomationProfileChoice(id: $0.name, configuration: $0.configuration) }
    }
}

struct CoolingAutomationView: View {
    @Bindable var model: AppModel
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automatic switching").font(.headline)
                    Text("Change profiles when an app opens, when you unplug, or at certain times.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Automatic switching", isOn: $model.automationEnabled).labelsHidden().toggleStyle(.switch)
            }
            if model.automationRules.isEmpty {
                Text("No rules yet. For example: Performance while Xcode is open, Quiet on battery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.automationRules.enumerated()), id: \.element.id) { index, rule in
                HStack(spacing: 10) {
                    Text("\(index + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 14)
                    Image(systemName: rule.symbol).foregroundStyle(BreezeStyle.mint).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.title).font(.subheadline)
                        Text("Use \(rule.profileName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.activeAutomationRule == rule.id {
                        Text("ACTIVE").font(.system(size: 8, weight: .semibold)).foregroundStyle(BreezeStyle.mint)
                            .padding(5).background(BreezeStyle.mint.opacity(0.12), in: Capsule())
                    }
                    Button { model.moveAutomationRule(rule.id, up: true) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(index == 0)
                        .accessibilityLabel("Move \(rule.title) up")
                    Button { model.removeAutomationRule(rule.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(rule.title)")
                }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("Add rule", systemImage: "plus") { editing = true }
                    .breezeAction().disabled(model.automationRules.count >= 24)
                Spacer()
                if let status = model.automationStatus {
                    Text(status).font(.caption).foregroundStyle(BreezeStyle.mint).lineLimit(1)
                }
            }
            Text("Rules are checked every few seconds, top to bottom; the first match wins. When no rule matches, Breeze returns to the profile you last applied. Timed boosts pause switching. Heat boost still applies to every profile.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $editing) { AutomationRuleEditor(model: model) }
    }
}

private struct AutomationRuleEditor: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    enum Kind: String, CaseIterable { case app = "An app is open", battery = "On battery", adapter = "On power adapter", schedule = "Time of day" }
    @State private var kind = Kind.app
    @State private var appID = ""
    @State private var appName = ""
    @State private var start = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: .now) ?? .now
    @State private var end = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now
    @State private var choice = CoolingPreset.performance.rawValue

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New switching rule").font(.title2.weight(.semibold))
            Picker("When", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            switch kind {
            case .app:
                HStack {
                    Menu(appName.isEmpty ? "Choose an app" : appName) {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                                appID = app.bundleIdentifier ?? ""; appName = app.localizedName ?? appID
                            }
                        }
                        Divider()
                        Button("Other app…") { chooseApp() }
                    }.fixedSize()
                    Spacer()
                }
            case .schedule:
                HStack {
                    DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: $end, displayedComponents: .hourAndMinute)
                }
            case .battery, .adapter: EmptyView()
            }
            Picker("Use profile", selection: $choice) {
                ForEach(model.automationChoices) { Text($0.id).tag($0.id) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add rule") { save(); dismiss() }.breezeAction(prominent: true)
                    .keyboardShortcut(.defaultAction).disabled(kind == .app && appID.isEmpty)
            }
        }.padding(28).frame(width: 460).breezeAction()
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        appID = id
        appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    private func save() {
        guard let profile = model.automationChoices.first(where: { $0.id == choice }) else { return }
        let trigger: AutomationRule.Trigger = switch kind {
        case .app: .app(bundleID: appID, name: appName)
        case .battery: .battery
        case .adapter: .adapter
        case .schedule: .schedule(start: minutes(start), end: minutes(end))
        }
        model.addAutomationRule(AutomationRule(trigger: trigger, profileName: profile.id, configuration: profile.configuration))
    }
}
