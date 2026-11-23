import AppKit
import CHardware
import FanCore
import NetworkCore
import Observation
import StorageCore
import SwiftUI
import UniformTypeIdentifiers

struct CheckupItem: Identifiable {
    enum Level: Int, Comparable {
        case good, tip, attention, issue
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        var title: String { ["Good", "Tip", "Attention", "Issue"][rawValue] }
        var symbol: String { ["checkmark.circle.fill", "lightbulb.fill", "exclamationmark.circle.fill", "xmark.octagon.fill"][rawValue] }
        var color: Color { [BreezeStyle.mint, BreezeStyle.blue, .orange, .red][rawValue] }
    }
    let id = UUID()
    let area: String
    let symbol: String
    let level: Level
    let title: String
    let detail: String
    var page: AppModel.Page?
}

/// A one-click review that reuses the readings Breeze already collects. Nothing is changed.
@MainActor @Observable
final class CheckupModel {
    var items: [CheckupItem] = []
    var running = false
    var date: Date?

    var summary: String {
        let issues = items.filter { $0.level >= .attention }.count
        if items.isEmpty { return "Run a checkup for a quick look at your Mac’s health." }
        return issues == 0 ? "Your Mac looks healthy." : "\(issues) thing\(issues == 1 ? " needs" : "s need") your attention."
    }

    func run(_ app: AppModel) async {
        guard !running else { return }
        running = true
        defer { running = false; date = .now }
        var result: [CheckupItem] = []
        func add(_ area: String, _ symbol: String, _ level: CheckupItem.Level, _ title: String, _ detail: String, page: AppModel.Page? = nil) {
            result.append(CheckupItem(area: area, symbol: symbol, level: level, title: title, detail: detail, page: page))
        }

        // Thermals and fans
        if let snapshot = app.snapshot {
            let hottest = snapshot.hottest.map { "\(Int($0))°C" } ?? "unavailable"
            switch (snapshot.thermalPressure, snapshot.hottest ?? 0) {
            case ("serious", _), ("critical", _):
                add("Thermals", "thermometer.high", .issue, "macOS reports \(snapshot.thermalPressure) thermal pressure",
                    "The hottest die is \(hottest). Performance may be throttled; check for heavy processes.", page: .statistics)
            case (_, 95...):
                add("Thermals", "thermometer.high", .attention, "The chip is running very hot", "The hottest die is \(hottest).", page: .cooling)
            default:
                add("Thermals", "thermometer.medium", .good, "Temperatures are normal", "Hottest die \(hottest) · thermal pressure \(snapshot.thermalPressure).")
            }
            if snapshot.fans.isEmpty {
                add("Fans", "fanblades", .good, "Passively cooled", "This Mac has no fans.")
            } else if let stuck = snapshot.fans.first(where: { $0.current == 0 }), (snapshot.hottest ?? 0) >= 85 {
                add("Fans", "fanblades", .attention, "\(stuck.name) reports 0 RPM while the chip is hot",
                    "Apple silicon fans rest when cool, but should spin under heavy load. Watch it in Cooling.", page: .cooling)
            } else {
                let fastest = Int(snapshot.fans.map(\.current).max() ?? 0)
                add("Fans", "fanblades", .good, fastest == 0 ? "Fans are resting" : "\(snapshot.fans.count) fan\(snapshot.fans.count == 1 ? "" : "s") reporting",
                    fastest == 0 ? "Normal while the chip is cool." : "Up to \(fastest) RPM.")
            }
        } else {
            add("Thermals", "sensor", .attention, "Sensor readings unavailable", app.readError ?? "Breeze could not read the hardware sensors.")
        }

        // Battery and charging
        var battery = await BatteryReader.read()
        if battery.availability == .available {
            await BatteryReader.health()?.apply(to: &battery)
            let health = battery.healthPercent.map { Int($0.rounded()) }
            let cycles = battery.cycles.map { " · \($0) cycles" } ?? ""
            if let condition = battery.condition, condition != "Normal" {
                add("Battery", "battery.25percent", .issue, "macOS reports battery condition: \(condition)", "Health \(health.map { "\($0)%" } ?? "unavailable")\(cycles).", page: .battery)
            } else if let health, health < 80 {
                add("Battery", "battery.25percent", .issue, "Battery health is \(health)%", "Apple considers batteries below 80% for service\(cycles).", page: .battery)
            } else if let health, health < 90 {
                add("Battery", "battery.50percent", .tip, "Battery health is \(health)%", "Some wear is normal\(cycles). A charge limit can slow further wear.", page: .battery)
            } else {
                add("Battery", "battery.100percent", .good, "Battery is in good shape", "Health \(health.map { "\($0)%" } ?? "unavailable")\(cycles).")
            }
            if let temperature = battery.temperature, temperature >= 40 {
                add("Battery", "thermometer.sun", .attention, "Battery is warm (\(Int(temperature))°C)", "Heat accelerates battery wear. Heat protection can pause charging.", page: .battery)
            }
            if app.charge.enabled {
                add("Charging", "powerplug", .good, "Charge limit is on at \(Int(app.charge.limit))%", app.chargeStatus ?? "Applies while Breeze is open.")
            } else {
                add("Charging", "powerplug", .tip, "No charge limit set", "If this Mac stays plugged in, holding the battery at 80% reduces wear.", page: .battery)
            }
        }

        // Storage
        if let space = DiskSpace.startup() {
            let fraction = Double(space.free) / Double(space.total)
            let text = "\(ByteCountFormatter.string(fromByteCount: space.free, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: space.total, countStyle: .file))."
            if fraction < 0.1 { add("Storage", "internaldrive", .issue, "Startup disk is nearly full", text + " macOS needs free space for updates and swap.", page: .storage) }
            else if fraction < 0.15 { add("Storage", "internaldrive", .attention, "Startup disk is getting full", text, page: .storage) }
            else { add("Storage", "internaldrive", .good, "Plenty of free space", text) }
        }
        if let drive = await StorageDriveReader.volumes().first(where: \.isStartup) {
            let health = drive.health
            if let status = health.status, status != "Verified" {
                add("SSD", "exclamationmark.triangle", .issue, "SMART status: \(status)", "Back up now and contact Apple Support.", page: .storage)
            } else if let life = health.lifeRemaining, life < 30 {
                add("SSD", "internaldrive", life < 10 ? .issue : .attention, "SSD endurance is \(life)% remaining", "Keep backups current.", page: .storage)
            } else if let errors = health.mediaErrors, errors > 0 {
                add("SSD", "internaldrive", .attention, "\(Int(errors)) media errors recorded", "Errors can precede drive failure. Keep backups current.", page: .storage)
            } else {
                add("SSD", "internaldrive", .good, "SSD looks healthy", health.lifeRemaining.map { "\($0)% estimated endurance remaining." } ?? "No SMART warnings reported.")
            }
        }
        if let inventory = app.storage.cleanup.inventory {
            let bytes = inventory.entries.filter { $0.risk == .rebuildable && !$0.action.isPermanent && $0.blockedReason == nil }.reduce(0) { $0 + $1.bytes }
            if bytes > 1_000_000_000 {
                add("Cleanup", "sparkles", .tip, "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of rebuildable files found",
                    "Caches and build output that tools recreate when needed.", page: .storage)
            }
        } else {
            add("Cleanup", "sparkles", .tip, "See what you can safely clear", "Run Find cleanup items in Storage → Cleanup & apps.", page: .storage)
        }

        // Memory and uptime
        var memory = BreezeMemory()
        if breeze_memory(&memory) == 0 {
            let swap = memory.swap_valid != 0 ? memory.swap_used : 0
            if memory.pressure == 4 { add("Memory", "memorychip", .issue, "Memory pressure is critical", "Quit apps you aren’t using.", page: .statistics) }
            else if memory.pressure == 2 { add("Memory", "memorychip", .attention, "Memory pressure is elevated", "macOS is compressing memory and may swap.", page: .statistics) }
            else if swap > 4_000_000_000 {
                add("Memory", "memorychip", .tip, "\(ByteCountFormatter.string(fromByteCount: Int64(swap), countStyle: .memory)) of swap in use", "A restart clears swap.")
            } else { add("Memory", "memorychip", .good, "Memory pressure is normal", "") }
        }
        let days = Int(SystemUptime.sinceBoot / 86_400)
        if days >= 14 { add("Uptime", "clock.arrow.circlepath", .tip, "Up for \(days) days", "A restart installs pending updates and clears swap.") }
        else { add("Uptime", "clock", .good, days == 0 ? "Restarted today" : "Up for \(days) day\(days == 1 ? "" : "s")", "") }

        // Connection and setup
        if UserDefaults.standard.object(forKey: "networkInternetChecks") as? Bool ?? true {
            let probe = await NetworkProbe.tcp(host: "1.1.1.1")
            if probe.reachable { add("Internet", "globe", .good, "Internet is reachable", probe.milliseconds.map { "\(Int($0)) ms to Cloudflare." } ?? "") }
            else { add("Internet", "globe", .attention, "Internet check failed", probe.evidence, page: .network) }
        }
        if app.helperStatus != .enabled {
            add("Setup", "lock.shield", .tip, "Cooling helper isn’t set up", "Approve it once to control fans and limit charging.", page: .settings)
        }
        items = result.sorted { $0.level > $1.level }
    }

    var report: String {
        var lines = ["# Breeze checkup", "", date.map { $0.formatted(date: .long, time: .shortened) } ?? "", "", summary, ""]
        for item in items {
            lines.append("- **\(item.level.title) · \(item.area):** \(item.title)" + (item.detail.isEmpty ? "" : " — \(item.detail)"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Breeze checkup.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct CheckupView: View {
    @Bindable var model: AppModel
    private var checkup: CheckupModel { model.checkup }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Checkup").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("One look at everything that matters.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if !checkup.items.isEmpty {
                    Button("Copy report", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(checkup.report, forType: .string)
                    }
                    Button("Save…", systemImage: "square.and.arrow.down") { checkup.save() }
                }
                Button(checkup.items.isEmpty ? "Run checkup" : "Run again", systemImage: "stethoscope") {
                    Task { await checkup.run(model) }
                }.breezeAction(prominent: true).disabled(checkup.running)
            }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: checkup.items.contains { $0.level >= .attention } ? "exclamationmark.circle" : "checkmark.seal")
                            .font(.system(size: 34, weight: .light)).foregroundStyle(checkup.items.contains { $0.level >= .attention } ? .orange : BreezeStyle.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(checkup.running ? "Checking your Mac…" : checkup.summary).font(.title3.weight(.semibold))
                            Text(checkup.date.map { "Last run \($0.formatted(date: .omitted, time: .shortened)) · thermals, battery, storage, memory and connection" }
                                 ?? "Reads sensors, battery, drives and memory. Nothing is changed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if checkup.running { ProgressView().controlSize(.small) }
                    }.padding(20).breezeSurface()
                    ForEach(checkup.items) { item in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: item.level.symbol).foregroundStyle(item.level.color).font(.title3).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.area.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                                Text(item.title).font(.subheadline.weight(.medium))
                                if !item.detail.isEmpty {
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            if let page = item.page, item.level != .good {
                                Button("Open \(page.rawValue)") { model.page = page }.breezeAction(size: .small)
                            }
                        }.padding(16).breezeSurface(radius: 16)
                    }
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .task { if checkup.items.isEmpty { await checkup.run(model) } }
    }
}
