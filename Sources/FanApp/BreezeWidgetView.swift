import AppKit
import Charts
import FanCore
import StorageCore
import SwiftUI

// The popup and preview share the same native glass shell and controls.
// Keep the hosting panel transparent so the material can sample its surroundings.
struct BreezeWidgetView: View {
    static let width: CGFloat = 352
    static let cornerRadius: CGFloat = 28

    @Bindable var model: AppModel
    var isPreview = false
    var maximumContentHeight: CGFloat = 440
    var openMainWindow: ((AppModel.Page) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat?
    @State private var scrub: Date?

    private var preferences: WidgetPreferences { model.widgetPreferences }
    private var reading: ActivityReading? {
        guard !model.sleeping, let latest = model.widgetActivity.latest,
              Date().timeIntervalSince(latest.date) < 8 else { return nil }
        return latest
    }
    private var thermalColor: Color {
        switch model.snapshot?.thermalPressure.lowercased() {
        case "serious", "critical": .orange
        default: BreezeStyle.mint
        }
    }

    private var heat: Double {
        BreezeMotion.heat(temperature: model.sleeping ? nil : model.snapshot?.hottest,
                          boost: model.configuration.boostTemperature)
    }
    // One value that changes whenever a notice appears, leaves or changes text.
    private var noticeKey: String {
        "\(model.sleeping)|\(model.readError != nil)|\(model.snapshot == nil)|\(model.message ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.sleeping {
                        notice("Readings paused while your Mac sleeps.", symbol: "moon.zzz").transition(.breezeDrop)
                    } else if model.readError != nil {
                        notice("Hardware readings unavailable. Waiting to reconnect…", symbol: "exclamationmark.triangle")
                            .transition(.breezeDrop)
                    } else if model.snapshot == nil {
                        notice("Waiting for live sensor readings…", symbol: "sensor").transition(.breezeDrop)
                    }
                    if !preferences.metrics.isEmpty { metrics }
                    coolingStatus
                    if preferences.sections.contains(.history) { temperatureHistory }
                    if preferences.sections.contains(.fans) { fanDetails }
                    if preferences.sections.contains(.cpu) { cpuDetails }
                    if preferences.sections.contains(.memory) { memoryDetails }
                    if preferences.sections.contains(.storage) { storageDetails }
                    if preferences.sections.contains(.sensors) { sensorDetails }
                    if preferences.sections.contains(.processes) { topProcesses }
                    if preferences.sections.contains(.devices) { deviceBatteries }
                    if preferences.sections.contains(.controls) { coolingControls }
                    if let message = model.message {
                        notice(message, symbol: "info.circle").transition(.breezeDrop)
                    }
                }
                .breezeAnimation(.settle, value: noticeKey)
                .padding(.horizontal, 18).padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Keep both presentations at their content height; detailed
            // configurations scroll within the same capped viewport.
            .frame(height: min(contentHeight ?? maximumContentHeight, maximumContentHeight))
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .breezeGlass(radius: Self.cornerRadius)
        // Constrain the content and glass to one silhouette. The popup's
        // NSPanel supplies the outer shadow beyond this rounded edge.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .tint(BreezeStyle.mint)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange?($0) }
        .task {
            model.widgetObservers += 1
            defer { model.widgetObservers -= 1 }
            do {
                while !Task.isCancelled { try await Task.sleep(for: .seconds(60)) }
            } catch { }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 21, weight: .medium)).foregroundStyle(BreezeStyle.mint)
                .frame(width: 38, height: 38)
                .background(BreezeStyle.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Breeze").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(isPreview ? "Live preview" : "Your Mac, at a glance")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showApp(.settings) } label: { settingsIcon }
                .breezeAction(size: .regular).buttonBorderShape(.circle)
                .help("Customize widget in Settings").accessibilityLabel("Customize widget")
        }
        .allowsHitTesting(!isPreview)
    }

    private var settingsIcon: some View {
        Image(systemName: "slider.horizontal.3").frame(width: 16, height: 16)
    }

    private var metrics: some View {
        VStack(spacing: 10) {
            let primary = [WidgetMetric.temperature, .fans].filter { preferences.metrics.contains($0) }
            if !primary.isEmpty {
                HStack(spacing: 10) {
                    ForEach(primary) { metric in
                        VStack(alignment: .leading, spacing: 7) {
                            Label(metric.title, systemImage: metric.symbol)
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            Text(WidgetValues.value(metric, model: model))
                                .font(.system(size: metric == .temperature ? 34 : 28, weight: .medium, design: .rounded))
                                .tracking(-1).breezeLive().lineLimit(1).minimumScaleFactor(0.65)
                                .foregroundStyle(metric == .temperature ? BreezeMotion.thermalColor(heat) : Color.primary)
                                .breezeAnimation(.settle, value: heat)
                            Text(metric == .temperature ? "Hottest die sensor" : fanCaption)
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity, minHeight: 91, alignment: .leading)
                            .padding(12).widgetInset()
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            let resources = [WidgetMetric.cpu, .gpu, .memory, .storage].filter { preferences.metrics.contains($0) }
            if !resources.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                        count: resources.count > 3 ? 2 : resources.count), spacing: 8) {
                    ForEach(resources) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: metric.symbol).foregroundStyle(BreezeStyle.blue)
                                Text(metric.title).foregroundStyle(.secondary)
                            }.font(.system(size: 10, weight: .medium))
                            Text(WidgetValues.value(metric, model: model))
                                .font(.system(size: 21, weight: .semibold, design: .rounded)).breezeLive()
                            meter(WidgetValues.percent(metric, model: model), color: BreezeStyle.blue)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).widgetInset()
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var fanCaption: String {
        guard !model.sleeping, let fans = model.snapshot?.fans else { return "Reading unavailable" }
        if fans.isEmpty { return "Passively cooled Mac" }
        if fans.allSatisfy({ $0.current == 0 }) { return "Fans are stopped" }
        return fans.count == 1 ? "Current fan speed" : "Fastest of \(fans.count) fans"
    }

    private var coolingStatus: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(model.snapshot == nil || model.sleeping ? Color.secondary : thermalColor)
                .frame(width: 6, height: 6).padding(.top, 4)
                .breezeAnimation(.settle, value: model.snapshot == nil || model.sleeping)
                .breezeAnimation(.settle, value: model.snapshot?.thermalPressure)
            Text(model.statusTitle).font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .breezeAnimation(.settle, value: model.statusTitle)
            Spacer(minLength: 4)
            if let remaining = model.boostRemaining {
                Text(remaining).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(BreezeStyle.mint)
                    .contentTransition(.numericText(countsDown: true))
                    .breezeAnimation(.settle, value: remaining)
                    .accessibilityLabel("Boost time remaining: \(remaining)")
                    .transition(.breezeFade)
            } else {
                Text(model.sleeping ? "PAUSED" : model.snapshot == nil ? "OFFLINE" : "LIVE")
                    .font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .transition(.breezeFade)
            }
        }
        .breezeAnimation(.settle, value: model.boostEndsAt != nil)
        .breezeAnimation(.settle, value: model.sleeping)
    }

    private var temperatureHistory: some View {
        let end = model.history.last?.date ?? Date()
        let samples = model.history.filter { $0.date.timeIntervalSince(end) >= -Double(preferences.historySeconds) }
        let low = max(0, (samples.map(\.temperature).min() ?? 40) - 5)
        let high = max(low + 15, (samples.map(\.temperature).max() ?? 70) + 5)
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Temperature", detail: "\(preferences.historySeconds / 60) MIN")
            Chart {
                ForEach(samples) { sample in
                    AreaMark(x: .value("Time", sample.date), yStart: .value("Baseline", low),
                             yEnd: .value("Temperature", sample.temperature))
                        .foregroundStyle(LinearGradient(colors: [BreezeStyle.mint.opacity(0.3), BreezeStyle.mint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", sample.date), y: .value("Temperature", sample.temperature))
                        .foregroundStyle(BreezeStyle.mint).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
                if let scrub, let near = BreezeMotion.nearest(samples, to: scrub, by: \.date) {
                    RuleMark(x: .value("Time", near.date))
                        .foregroundStyle(.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            BreezeChartCallout(title: near.date.formatted(date: .omitted, time: .standard),
                                               value: "\(Int(near.temperature))°C")
                        }
                    PointMark(x: .value("Time", near.date), y: .value("Temperature", near.temperature))
                        .symbolSize(48).foregroundStyle(BreezeStyle.mint)
                }
            }
            .chartXScale(domain: end.addingTimeInterval(-Double(preferences.historySeconds))...end)
            .chartYScale(domain: low...high).chartXAxis(.hidden).chartYAxis(.hidden)
            .breezeChartScrub($scrub)
            .breezeChartKeys($scrub, dates: samples.map(\.date))
            .frame(height: 66)
            .overlay {
                if samples.count < 2 {
                    Text("Collecting temperature history…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Temperature history over \(preferences.historySeconds / 60) minutes")
            .accessibilityValue(samples.last.map { "Latest: \(Int($0.temperature)) degrees Celsius" } ?? "No samples")
            HStack {
                Text("\(preferences.historySeconds / 60)m ago")
                Spacer()
                if let min = samples.map(\.temperature).min(), let max = samples.map(\.temperature).max() {
                    Text("\(Int(min))–\(Int(max))°C").breezeLive()
                }
                Spacer()
                Text(model.sleeping ? "Paused" : model.snapshot == nil ? "Last reading" : "Now")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(12).widgetInset()
    }

    private var fanDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Fans", detail: "RPM")
            if let fans = model.snapshot?.fans, !model.sleeping {
                if fans.isEmpty { Text("This Mac is passively cooled.").font(.caption).foregroundStyle(.secondary) }
                ForEach(fans) { fan in
                    VStack(alignment: .leading, spacing: 6) {
                        valueRow(fan.name, value: "\(Int(fan.current))", symbol: "fanblades")
                        meter(fan.maximum > 0 ? fan.current / fan.maximum * 100 : nil, color: BreezeStyle.mint)
                        HStack {
                            Text(fan.isManual ? "Manual" : "Automatic")
                                .contentTransition(.opacity).breezeAnimation(.settle, value: fan.isManual)
                            Spacer()
                            Text("\(Int(fan.minimum))–\(Int(fan.maximum)) RPM")
                        }.font(.system(size: 9)).foregroundStyle(.secondary).breezeLive()
                    }
                }
            } else { waiting("Waiting for fan readings…") }
        }.padding(12).widgetInset()
    }

    private var cpuDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Processor", detail: "\(model.widgetActivity.logicalCores) CORES")
            if let cpu = reading?.cpu {
                HStack {
                    component("User", value: percent(cpu.user), color: BreezeStyle.blue)
                    Spacer(minLength: 2)
                    component("System", value: percent(cpu.system), color: .orange)
                    Spacer(minLength: 2)
                    component("Idle", value: percent(cpu.idle), color: .secondary)
                }
                if let cores = reading?.cores, !cores.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                        ForEach(cores.indices, id: \.self) { index in
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.05))
                                    .overlay(alignment: .bottom) {
                                        RoundedRectangle(cornerRadius: 3).fill(BreezeStyle.blue.opacity(0.8))
                                            .frame(height: proxy.size.height * min(1, max(0, (cores[index]?.used ?? 0) / 100)))
                                            .breezeAnimation(.drift, value: cores[index]?.used)
                                    }
                            }.frame(height: 28)
                                .accessibilityLabel("Core \(index + 1)").accessibilityValue(percent(cores[index]?.used))
                                .help("Core \(index + 1): \(percent(cores[index]?.used))")
                        }
                    }
                }
            } else { waiting("Collecting CPU activity…") }
            if let load = reading?.load, load.count == 3 {
                valueRow("Load · 1 / 5 / 15 min", value: load.map { String(format: "%.2f", $0) }.joined(separator: " / "))
            }
            valueRow("Uptime", value: model.systemStats.map { uptime($0.uptime) } ?? "—")
        }.padding(12).widgetInset()
    }

    private var memoryDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Memory", detail: reading?.memory.map { "\(WidgetValues.gib($0.used)) / \(WidgetValues.gib($0.total)) GB" })
            if let memory = reading?.memory {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Rectangle().fill(BreezeStyle.blue).frame(width: proxy.size.width * fraction(memory.app, memory.total))
                        Rectangle().fill(.orange).frame(width: proxy.size.width * fraction(memory.wired, memory.total))
                        Rectangle().fill(.pink).frame(width: proxy.size.width * fraction(memory.compressed, memory.total))
                        Spacer(minLength: 0)
                    }.background(.primary.opacity(0.08)).clipShape(Capsule())
                }.frame(height: 6).accessibilityLabel("Memory composition")
                valueRow("App", value: bytes(memory.app), color: BreezeStyle.blue)
                valueRow("Wired", value: bytes(memory.wired), color: .orange)
                valueRow("Compressed", value: bytes(memory.compressed), color: .pink)
                valueRow("Available", value: bytes(memory.available))
                valueRow("Swap", value: memory.swapUsed.map(bytes) ?? "Unavailable")
                valueRow("Pressure", value: memory.pressure == 1 ? "Normal" : memory.pressure == 2 ? "Warning" : memory.pressure == 4 ? "Critical" : "Unavailable")
            } else { waiting("Waiting for memory readings…") }
        }.padding(12).widgetInset()
    }

    private var storageDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Storage", detail: "STARTUP DISK")
            if let drive = WidgetValues.storageDrive(model: model) {
                Text(drive.name).font(.system(size: 11, weight: .medium))
                meter(drive.usedFraction * 100, color: BreezeStyle.blue)
                valueRow("Used", value: diskBytes(drive.used))
                valueRow("Free", value: diskBytes(drive.free))
                valueRow("Capacity", value: diskBytes(drive.total))
                if let sample = model.widgetStorage.latest, Date().timeIntervalSince(sample.date) < 8 {
                    valueRow("Read", value: diskRate(sample.readRate), color: BreezeStyle.mint)
                    valueRow("Write", value: diskRate(sample.writeRate), color: BreezeStyle.blue)
                } else {
                    waiting(model.widgetStorage.activityDevice == nil
                            ? "Disk activity is unavailable for this volume."
                            : "Collecting disk activity…")
                }
                Button { showApp(.storage) } label: {
                    Label("Open Storage", systemImage: "arrow.up.right")
                }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(BreezeStyle.mint)
                    .allowsHitTesting(!isPreview)
            } else {
                waiting(model.sleeping ? "Storage readings paused."
                        : model.widgetStorage.loading ? "Reading startup disk…" : "Startup disk readings unavailable.")
            }
        }.padding(12).widgetInset()
    }

    private func diskBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }
    private func diskRate(_ value: Double) -> String {
        diskBytes(Int64(min(Double(Int64.max - 1024), max(0, value)))) + "/s"
    }

    private var sensorDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Thermals")
            valueRow("Thermal pressure", value: model.sleeping ? "Paused" : model.snapshot?.thermalPressure.capitalized ?? "Unavailable")
            valueRow("CPU die", value: model.sleeping ? "—" : degrees(model.snapshot?.cpuTemperature))
            valueRow("GPU die", value: model.sleeping ? "—" : degrees(model.snapshot?.gpuTemperature))
            if let sensors = model.snapshot?.temperatures, !sensors.isEmpty, !model.sleeping {
                BreezeDisclosure("Die sensors · \(sensors.count) readings") {
                    VStack(spacing: 8) {
                        ForEach(sensors, id: \.key) { sensor in
                            valueRow(sensor.key, value: String(format: "%.1f°C", sensor.celsius))
                                .fontDesign(.monospaced)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(12).widgetInset()
    }

    private var topProcesses: some View {
        let processes = reading == nil ? [] : model.widgetActivity.processes.sorted { $0.cpuSort > $1.cpuSort }.prefix(5).map { $0 }
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Top processes", detail: "CPU / MEMORY")
            if processes.isEmpty {
                waiting(model.widgetActivity.processError ?? "Collecting process activity…")
            } else {
                ForEach(processes) { process in
                    HStack(spacing: 8) {
                        Text(process.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(percent(process.cpu)).breezeLive().frame(width: 45, alignment: .trailing)
                        Text(process.memory.map(bytes) ?? "—").foregroundStyle(.secondary)
                            .breezeLive().frame(width: 60, alignment: .trailing)
                    }.font(.system(size: 10))
                }
                Text("CPU is per core; a process can exceed 100%.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.padding(12).widgetInset()
    }

    private var deviceBatteries: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Devices", detail: "BATTERY")
            if let device = model.deviceBatteries.needsAccess.first, !model.deviceBatteries.accessDismissed {
                Button { showApp(.battery) } label: {
                    Label("Show \(device) battery…", systemImage: "computermouse").lineLimit(1)
                }.buttonStyle(.link).font(.system(size: 10))
            }
            if model.deviceBatteries.devices.isEmpty {
                waiting(model.deviceBatteries.updated == nil ? "Looking for Bluetooth devices…" : "No connected device reports a battery level.")
            } else {
                ForEach(model.deviceBatteries.devices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.symbol).foregroundStyle(BreezeStyle.blue).frame(width: 16)
                        Text(device.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(device.levels.map { ($0.label.isEmpty ? "" : "\($0.label.prefix(1)) ") + "\($0.percent)%" }.joined(separator: "  "))
                            .breezeLive().foregroundStyle((device.lowest ?? 100) <= 20 ? .orange : .primary)
                    }.font(.system(size: 10))
                }
            }
        }.padding(12).widgetInset()
    }

    private var coolingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Cooling")
            if model.snapshot?.canControl == true {
                BreezeGlassGroup(spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            guard !isPreview else { return }
                            Task { await model.automatic() }
                        } label: {
                            Label("Automatic", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                                .frame(maxWidth: .infinity)
                        }.widgetButton(prominent: model.activeMode == .automatic && !model.manual)
                        Menu {
                            ForEach([1, 5, 10, 15, 30], id: \.self) { minutes in
                                Button("\(minutes) minute\(minutes == 1 ? "" : "s")") {
                                    guard !isPreview else { return }
                                    Task { await model.startTimedBoost(minutes: minutes) }
                                }
                            }
                        } label: { boostLabel }
                            .menuIndicator(.hidden)
                            .widgetButton(prominent: model.boostEndsAt != nil)
                    }
                }
                HStack {
                    if model.boostEndsAt != nil {
                        Button("End timed boost") {
                            guard !isPreview else { return }
                            Task { await model.endTimedBoost() }
                        }.transition(.breezeFade)
                    } else {
                        Button("Maximum cooling · 100%") {
                            guard !isPreview else { return }
                            Task { await model.maximum() }
                        }.transition(.breezeFade)
                    }
                    Spacer(minLength: 0)
                    if model.busy { ProgressView().controlSize(.mini).transition(.breezeFade) }
                }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                    .breezeAnimation(.settle, value: model.busy)
            } else if model.snapshot?.fans.isEmpty == true {
                waiting("This Mac doesn’t need a cooling fan.")
            } else {
                Button("Open cooling setup") { showApp(.cooling) }.widgetButton()
            }
        }.disabled(model.busy || model.sleeping).allowsHitTesting(!isPreview)
    }

    private var boostLabel: some View {
        HStack(spacing: 6) {
            Label("Boost", systemImage: "wind")
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }.frame(maxWidth: .infinity)
    }

    private var footer: some View {
        BreezeGlassGroup(spacing: 8) {
            HStack {
                Button { showApp(.overview) } label: { Label("Open Breeze", systemImage: "arrow.up.right") }
                    .breezeAction(size: .regular)
                Spacer()
                Button {
                    guard !isPreview else { return }
                    NSApplication.shared.terminate(nil)
                } label: { Image(systemName: "power") }
                    .breezeAction(size: .regular).buttonBorderShape(.circle)
                    .help("Quit Breeze").accessibilityLabel("Quit Breeze")
            }
        }.font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 13)
            .allowsHitTesting(!isPreview)
    }

    private func showApp(_ page: AppModel.Page) {
        guard !isPreview else { return }
        if let openMainWindow {
            openMainWindow(page)
            return
        }
        model.page = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            if let detail { Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
    private func valueRow(_ title: String, value: String, symbol: String? = nil, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 5, height: 5) }
            if let symbol { Image(systemName: symbol).foregroundStyle(BreezeStyle.mint) }
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).fontWeight(.medium).breezeLive()
        }.font(.system(size: 10)).accessibilityElement(children: .combine)
    }
    private func component(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 4, height: 4)
                Text(title).foregroundStyle(.secondary)
            }.font(.system(size: 9))
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).breezeLive()
        }
    }
    private func meter(_ percent: Double?, color: Color) -> some View {
        BreezeMeter(fraction: percent.map { $0 / 100 }, tint: color, height: 4).accessibilityHidden(true)
    }
    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func waiting(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
    private func degrees(_ value: Double?) -> String { value.map { "\(Int($0))°C" } ?? "—" }
    private func fraction(_ value: UInt64, _ total: UInt64) -> Double { total > 0 ? min(1, Double(value) / Double(total)) : 0 }
    private func uptime(_ seconds: TimeInterval) -> String {
        let hours = max(0, Int(seconds)) / 3600
        return hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h \(Int(seconds) / 60 % 60)m"
    }
}

@MainActor enum WidgetValues {
    static func storageDrive(model: AppModel) -> StorageDrive? {
        guard !model.sleeping, let updated = model.widgetStorage.updated,
              Date().timeIntervalSince(updated) < 40,
              let drive = model.widgetStorage.selected, drive.isStartup else { return nil }
        return drive
    }

    static func percent(_ metric: WidgetMetric, model: AppModel) -> Double? {
        guard !model.sleeping else { return nil }
        switch metric {
        case .cpu: return model.readError == nil ? model.systemStats?.cpuPercent : nil
        case .gpu:
            guard let latest = model.widgetActivity.latest, Date().timeIntervalSince(latest.date) < 8 else { return nil }
            return latest.gpus.compactMap(\.utilization).max()
        case .memory:
            guard model.readError == nil, let stats = model.systemStats, stats.memoryTotal > 0 else { return nil }
            return Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
        case .storage: return storageDrive(model: model).map { $0.usedFraction * 100 }
        case .battery: return model.menuBarReadings.battery.map { Double($0.percent) }
        case .temperature, .fans, .network: return nil
        }
    }
    static func value(_ metric: WidgetMetric, model: AppModel) -> String {
        guard !model.sleeping else { return "—" }
        switch metric {
        case .temperature: return model.snapshot?.hottest.map { "\(Int($0))°C" } ?? "—"
        case .fans:
            guard let fans = model.snapshot?.fans else { return "—" }
            if fans.isEmpty { return "Fanless" }
            return "\(model.rpmLabel) RPM"
        case .cpu, .gpu, .memory, .storage: return percent(metric, model: model).map { String(format: "%.0f%%", $0) } ?? "—"
        case .network: return model.menuBarReadings.traffic.map { "↓ " + MenuBarReadings.rate($0.download) } ?? "—"
        case .battery:
            guard let battery = model.menuBarReadings.battery else { return "—" }
            return (battery.charging ? "⚡︎" : "") + "\(battery.percent)%"
        }
    }
    static func gib(_ value: UInt64) -> String { String(format: "%.1f", Double(value) / 1_073_741_824) }
}

struct WidgetMenuBarReading: Identifiable, Equatable {
    let metric: WidgetMetric
    let value: String
    /// Upload rate under the download rate for the network reading.
    var secondary: String? = nil
    var id: WidgetMetric { metric }
    // Reserve the complete range before any live values arrive. Changing digit
    // counts or showing an unavailable reading must not move menu bar items.
    var widthReference: String {
        switch metric {
        case .temperature: "100°C"
        case .fans: "10000 RPM"
        case .cpu, .gpu, .memory, .storage: "100%"
        case .network: "↓ 999 KB/s"
        case .battery: "⚡︎100%"
        }
    }
    var title: String {
        switch metric {
        case .temperature: "TEMP"
        case .fans: "FAN"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        case .storage: "DISK"
        case .network: "NET"
        case .battery: "BAT"
        }
    }

    @MainActor static func current(model: AppModel) -> [Self] {
        WidgetMetric.allCases.filter { model.widgetPreferences.menuMetrics.contains($0) }
            .map { metric in
                let upload = metric == .network && !model.sleeping ? model.menuBarReadings.traffic.map { "↑ " + MenuBarReadings.rate($0.upload) } : nil
                return Self(metric: metric, value: WidgetValues.value(metric, model: model),
                            secondary: metric == .network ? upload ?? "—" : nil)
            }
    }
}

struct WidgetMenuBarLabel: View {
    let model: AppModel
    var body: some View {
        WidgetMenuBarContent(readings: WidgetMenuBarReading.current(model: model))
    }
}

// This exact layout is used by the Settings preview and rendered into the
// NSStatusItem image. MenuBarExtra's label conversion can discard nested text.
struct WidgetMenuBarContent: View {
    let readings: [WidgetMenuBarReading]
    var showsFanIcon = true
    /// Separate extra items carry no fan icon and no space for one.
    var reservesFanIcon = true
    /// Separate items always name their reading, since a lone "42%" is ambiguous.
    var titled = false

    var body: some View {
        HStack(spacing: 9) {
            if reservesFanIcon { WidgetMenuBarFanIcon().opacity(showsFanIcon ? 1 : 0) }
            ForEach(readings) { reading in
                if let secondary = reading.secondary {
                    VStack(alignment: .trailing, spacing: 0) {
                        valueLabel(reading, font: .system(size: 9, weight: .semibold))
                        valueLabel(WidgetMenuBarReading(metric: reading.metric, value: secondary), font: .system(size: 9, weight: .semibold))
                    }
                } else if readings.count == 1 && !titled {
                    valueLabel(reading, font: .system(size: 11, weight: .medium))
                } else {
                    VStack(spacing: 0) {
                        Text(reading.title).font(.system(size: 7, weight: .medium))
                        valueLabel(reading, font: .system(size: 10, weight: .semibold))
                    }
                }
            }
        }
        .fixedSize().frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Breeze")
        .accessibilityValue(readings.map { "\($0.metric.title): \([$0.value, $0.secondary].compactMap { $0 }.joined(separator: " "))" }.joined(separator: ", "))
    }

    private func valueLabel(_ reading: WidgetMenuBarReading, font: Font) -> some View {
        Text(reading.widthReference)
            .hidden()
            .overlay {
                Text(reading.value).lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(font).monospacedDigit()
    }
}

struct WidgetMenuBarFanIcon: View {
    var body: some View {
        Image(systemName: "fanblades").font(.system(size: 14)).frame(width: 16)
    }
}

private struct WidgetButtonStyle: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .breezeAction(prominent: prominent, size: .regular)
            .frame(maxWidth: .infinity)
    }
}

private struct WidgetInset: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        content
            .background(.primary.opacity(0.035), in: shape)
            .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.25 : 0.045), lineWidth: 0.5))
    }
}

private extension View {
    func widgetInset() -> some View {
        modifier(WidgetInset())
    }
    func widgetButton(prominent: Bool = false) -> some View { modifier(WidgetButtonStyle(prominent: prominent)) }
}
