import Charts
import FanCore
import SwiftUI

struct Dashboard: View {
    @Bindable var model: AppModel
    @State private var exporting = false
    @State private var exportDocument = CoolingHistoryDocument(text: "")
    private let accent = BreezeStyle.mint

    var body: some View {
        BreezeGlassGroup(spacing: 8) {
            HStack(spacing: 12) {
                sidebar.breezeGlass(radius: 26).padding(.vertical, 12).padding(.leading, 12)
                content
            }
        }
        .frame(minWidth: 1020, minHeight: 740)
        .background { BreezeBackdrop() }
        .tint(accent)
        .breezeAction(size: .regular)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "Breeze-cooling-history") { result in
            if case .failure(let error) = result { model.message = error.localizedDescription }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "fanblades.fill").font(.system(size: 27)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Breeze").font(.system(size: 23, weight: .semibold, design: .rounded))
                    Text("A little breathing room.").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 36)
            List(selection: Binding<AppModel.Page?>(
                get: { model.page },
                set: { if let page = $0 { model.page = page } }
            )) {
                ForEach(AppModel.Page.allCases, id: \.self) { page in
                    HStack(spacing: 10) {
                        Label(page.rawValue, systemImage: page.symbol)
                            .font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if page == .storage, model.storage.busy { ProgressView().controlSize(.mini) }
                    }
                    .frame(minHeight: 30)
                    .tag(page)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 8) {
                Label(model.statusTitle, systemImage: "circle.fill").font(.caption).foregroundStyle(accent)
                Text("\(model.rpmLabel) RPM").font(.system(size: 21, weight: .light, design: .rounded)).monospacedDigit()
                Text(model.boostRemaining.map { "Timed boost · \($0) left" } ?? "Live cooling status").font(.caption2).foregroundStyle(.secondary)
            }.padding(20)
        }.frame(width: 208)
    }

    @ViewBuilder private var content: some View {
        if model.page == .storage {
            StorageView(model: model.storage)
        } else if model.page == .statistics {
            ActivityView(model: model.activity, thermal: statistics)
        } else if model.page == .network {
            NetworkView(model: model.network)
        } else if model.page == .mac {
            MacInfoView(model: model.macInfo)
        } else if model.page == .battery {
            BatteryView(model: model.battery)
        } else {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.page.rawValue).font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(pageSubtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.snapshot == nil ? .orange : accent).frame(width: 6, height: 6)
                Text(model.enabled ? "Control connected" : "Monitoring").font(.caption).foregroundStyle(.secondary)
                Button { Task { await model.automatic() } } label: { Label("Automatic", systemImage: "arrow.uturn.backward") }
                    .breezeAction().disabled(model.busy || model.snapshot?.canControl != true)
                    .help("Return fan control to macOS")
            }.padding(.horizontal, 26).padding(.top, 30).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.page != .settings { metrics }
                    if let error = model.readError { notice(error, color: .orange) }
                    if let message = model.message { notice(message, color: .orange) }
                    switch model.page {
                    case .overview: overview
                    case .cooling: cooling
                    case .statistics: statistics
                    case .settings: settings
                    case .storage, .network, .mac, .battery: EmptyView()
                    }
                }.padding(.horizontal, 26).padding(.bottom, 20)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(accent)
                Text(model.statusDetail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 26).frame(height: 54)
        }
        }
    }

    private var pageSubtitle: String {
        switch model.page {
        case .overview: "A clearer view of your Mac."
        case .cooling: "Find the balance for the way you work."
        case .statistics: "Live readings. A little more perspective."
        case .settings: "Make Breeze feel at home."
        case .storage: "See what’s taking up space."
        case .network: "Your connection, and the devices around it."
        case .mac: "Get to know the Mac you’re working on."
        case .battery: "Charge, health, and the power coming in."
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            OverviewSummaryView(model: model)
            temperatureChart.padding(20).breezeSurface()
            HStack(spacing: 12) {
                destination(.battery, title: "Power, in perspective", detail: "Charge, battery health & live power flow.", color: accent)
                destination(.network, title: "Know your connection", detail: "Traffic, internet quality & nearby devices.", color: BreezeStyle.blue)
                destination(.storage, title: "Room for what’s next", detail: "Drive health, space maps & file cleanup.", color: .orange)
            }
            fanList.padding(20).breezeSurface()
        }
    }
    private func destination(_ page: AppModel.Page, title: String, detail: String, color: Color) -> some View {
        Button { model.page = page } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: page.symbol).font(.title2).foregroundStyle(color); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) }
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .breezeGlass(interactive: true)
        }.buttonStyle(.plain)
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric("CPU die", value: degrees(model.snapshot?.cpuTemperature), symbol: "cpu")
            metric("GPU die", value: degrees(model.snapshot?.gpuTemperature), symbol: "square.3.layers.3d")
            metric("CPU load", value: model.systemStats?.cpuPercent.map { "\(Int($0))%" } ?? "—", symbol: "waveform.path")
            metric("Memory", value: model.systemStats.map { "\(gib($0.memoryUsed)) GB" } ?? "—", symbol: "memorychip")
        }
    }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Image(systemName: symbol).font(.caption).foregroundStyle(accent)
            }
            Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .breezeSurface()
    }
    private var cooling: some View {
        VStack(alignment: .leading, spacing: 18) {
            CoolingControlsView(model: model)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your cooling profile").font(.headline)
                    Text("Keep working. Let the fans do more.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.maximum() } } label: { Label("Maximum cooling", systemImage: "fanblades.fill") }
                    .breezeAction(prominent: true).tint(accent)
                    .disabled(model.busy || model.snapshot?.canControl != true)
            }
            VStack(alignment: .leading, spacing: 16) {
                Picker("Cooling mode", selection: $model.configuration.mode) {
                    ForEach(CoolingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                switch model.configuration.mode {
                case .automatic:
                    Text("macOS chooses fan speeds. Select a custom profile or Maximum cooling to set your own targets.")
                        .font(.caption).foregroundStyle(.secondary)
                case .manual:
                    HStack {
                        Text("Fixed speed").font(.subheadline)
                        Spacer()
                        Text("\(Int(model.configuration.manualPercent))%").font(.title3).monospacedDigit()
                    }
                    Slider(value: $model.configuration.manualPercent, in: 0...100, step: 1).tint(accent)
                        .accessibilityLabel("Fixed fan speed")
                    HStack { Text("Hardware minimum"); Spacer(); Text("Hardware maximum") }.font(.caption2).foregroundStyle(.secondary)
                    Text(fixedSpeedPreview).font(.caption).foregroundStyle(accent)
                case .curve: curveEditor
                case .target:
                    HStack(alignment: .firstTextBaseline) {
                        Text("Aim to stay below").font(.subheadline)
                        Spacer()
                        Text("\(Int(model.configuration.targetTemperature))°C")
                            .font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
                    }
                    Slider(value: $model.configuration.targetTemperature, in: 40...90, step: 1).tint(accent)
                        .accessibilityLabel("Target die temperature")
                    Text("Fan speed adapts to the hottest die sensor and how quickly it is heating up. If full fan speed cannot meet the target, Breeze will say so.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(model.helperStatus == .enabled ? "Apply changes to activate this profile." : "Approve the cooling helper once in Settings to enable fan control.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.configuration.mode == .automatic ? "Use Automatic" : "Apply profile") { Task { await model.apply() } }
                        .breezeAction(prominent: true).tint(accent)
                        .disabled(model.busy || model.snapshot?.canControl != true)
                }
            }.padding(20).breezeSurface()
            fanList.padding(20).breezeSurface()
            temperatureChart.padding(20).breezeSurface()
        }
    }
    private var curveEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fan speed by temperature").font(.subheadline)
                Spacer()
                Button("Balanced") { model.configuration.points = CoolingConfiguration().points }
                Button("Performance") {
                    model.configuration.points = [CurvePoint(temperature: 35, percent: 35), CurvePoint(temperature: 50, percent: 60),
                                                  CurvePoint(temperature: 60, percent: 85), CurvePoint(temperature: 70, percent: 100)]
                }
            }.controlSize(.small)
            Chart {
                ForEach(model.configuration.points.sorted { $0.temperature < $1.temperature }) { point in
                    LineMark(x: .value("°C", point.temperature), y: .value("Speed %", point.percent)).foregroundStyle(accent)
                    PointMark(x: .value("°C", point.temperature), y: .value("Speed %", point.percent)).foregroundStyle(accent)
                }
                if let temperature = model.snapshot?.hottest {
                    RuleMark(x: .value("Current temperature", temperature)).foregroundStyle(.orange.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }.chartXScale(domain: 20...110).chartYScale(domain: 0...100).frame(height: 115)
                .chartXAxisLabel("Die temperature, °C").chartYAxisLabel("Fan %")
            ForEach(model.configuration.points.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Text("Point \(i+1)").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    TextField("Temperature", value: $model.configuration.points[i].temperature, format: .number.precision(.fractionLength(0)))
                        .frame(width: 64).accessibilityLabel("Point \(i+1) temperature")
                    Text("°C").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Speed", value: $model.configuration.points[i].percent, format: .number.precision(.fractionLength(0)))
                        .frame(width: 64).accessibilityLabel("Point \(i+1) speed")
                    Text("%").font(.caption).foregroundStyle(.secondary)
                    Button { model.configuration.points.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.configuration.points.count <= 2)
                        .accessibilityLabel("Remove point \(i+1)")
                }.textFieldStyle(.roundedBorder)
            }
            Button("Add curve point", systemImage: "plus") { addCurvePoint() }
                .disabled(model.configuration.points.count >= 12)
            Text("Temperatures must increase. Fan speeds can stay level or increase. The orange line is the live die temperature.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var fanList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Fans").font(.headline)
                Spacer()
                if let applied = model.appliedPercent { Text("Applied \(Int(applied))% of range").font(.caption).foregroundStyle(accent) }
            }
            if model.snapshot?.fans.isEmpty == true { Text("This Mac has no fans to control.").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.snapshot?.fans ?? []) { fan in
                VStack(spacing: 7) {
                    HStack {
                        Image(systemName: "fanblades").foregroundStyle(accent)
                        Text(fan.name).font(.subheadline)
                        Text(fan.isManual ? "MANUAL" : "SYSTEM").font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary).padding(5).background(.quaternary, in: Capsule())
                        Spacer()
                        Text("\(Int(fan.current)) RPM").font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    ProgressView(value: min(1, max(0, fan.current/max(1, fan.maximum))))
                        .tint(accent).accessibilityLabel("\(fan.name) actual fan speed")
                    HStack {
                        Text("Range \(max(0, Int(fan.minimum)))–\(max(0, Int(fan.maximum))) RPM")
                        Spacer()
                        Text(fan.target.map { "Target \(Int($0)) RPM" } ?? "Target unavailable")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var temperatureChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Thermal history").font(.headline)
                Spacer()
                Picker("History range", selection: $model.historySeconds) {
                    Text("2 min").tag(120); Text("5 min").tag(300); Text("10 min").tag(600)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Button {
                    exportDocument = CoolingHistoryDocument(text: model.historyCSV)
                    exporting = true
                } label: { Image(systemName: "square.and.arrow.up") }
                    .breezeAction().help("Export the selected history as CSV")
                    .accessibilityLabel("Export cooling history").disabled(model.visibleHistory.isEmpty)
            }
            HStack(spacing: 18) {
                Label("Hottest die", systemImage: "circle.fill").foregroundStyle(accent)
                Text("Peak \(degrees(model.visibleHistory.map(\.temperature).max()))")
                Text("Average \(degrees(historyAverage))")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            Chart(model.visibleHistory) { sample in
                AreaMark(x: .value("Time", sample.date), yStart: .value("Baseline", 0), yEnd: .value("°C", sample.temperature))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", sample.date), y: .value("°C", sample.temperature)).foregroundStyle(accent)
            }.chartYScale(domain: 0...110).chartXAxis(.hidden).frame(height: 115)
                .overlay { if model.visibleHistory.isEmpty { Text("Collecting temperature readings…").font(.caption).foregroundStyle(.secondary) } }
            Text("Only collected readings are shown. Export includes temperature, fastest fan speed and CPU load.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var historyAverage: Double? {
        let values = model.visibleHistory.map(\.temperature)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    private var fixedSpeedPreview: String {
        let fans = model.snapshot?.fans ?? []
        return fans.map { fan in
            let lower = min(fan.maximum, max(1200, fan.minimum))
            let rpm = lower + (fan.maximum - lower) * model.configuration.manualPercent / 100
            return "\(fan.name): ~\(Int(rpm)) RPM"
        }.joined(separator: "  ·  ")
    }
    private var statistics: some View {
        VStack(alignment: .leading, spacing: 20) {
            fanList
            temperatureChart
            VStack(alignment: .leading, spacing: 10) {
                Text("Fan speed history").font(.headline)
                Chart(model.history) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("RPM", sample.rpm)).foregroundStyle(accent)
                }.chartXAxis(.hidden).frame(height: 100)
            }
            HStack {
                Label("Thermal pressure", systemImage: "thermometer.medium")
                Spacer()
                Text(model.snapshot?.thermalPressure.capitalized ?? "Unknown").foregroundStyle(.secondary)
            }.font(.subheadline)
            if let stats = model.systemStats {
                HStack {
                    Label("Memory used / physical", systemImage: "memorychip")
                    Spacer()
                    Text("\(gib(stats.memoryUsed)) / \(gib(stats.memoryTotal)) GB").foregroundStyle(.secondary)
                }.font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Die sensors").font(.headline)
                Text("Raw sensor keys vary by Mac. Cooling follows the hottest valid die reading.").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(model.snapshot?.temperatures ?? [], id: \.key) { sensor in
                        HStack {
                            Text(sensor.key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Text(degrees(sensor.celsius)).font(.caption).monospacedDigit()
                        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 24) {
            WidgetSettingsView(model: model)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Cooling helper").font(.headline)
                Text(model.helperStatus == .enabled ? "Approved · ready for fan control" : model.helperStatus == .requiresApproval ? "Waiting for approval in System Settings" : "One-time setup required")
                    .font(.subheadline)
                Text("Approve Breeze’s background helper once. It handles fan changes on future launches without asking for your password each session. No password is saved.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.helperStatus == .enabled {
                        Button("Manage approval") { model.openHelperSettings() }
                        Button("Remove helper", role: .destructive) { Task { await model.removeHelper() } }
                    } else {
                        Button(model.helperStatus == .requiresApproval ? "Open System Settings" : "Set up cooling helper") { model.setupHelper() }
                    }
                }.disabled(model.busy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Sleep & startup").font(.headline)
                Toggle("Resume the active cooling profile after wake", isOn: $model.resumeOnWake)
                Text("Breeze pauses overrides during sleep and keeps its authorized helper connected. It resumes the profile when the Mac wakes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Apply the saved profile when Breeze opens", isOn: $model.applyAtLaunch)
                Toggle("Open Breeze at login", isOn: Binding(get: { model.loginEnabled }, set: { value in Task { await model.setLoginEnabled(value) } }))
                Text("Opening at login is optional and separate from cooling helper approval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Heat boost").font(.headline)
                HStack {
                    Text("Use maximum cooling at")
                    Spacer()
                    Stepper("\(Int(model.configuration.boostTemperature))°C", value: $model.configuration.boostTemperature, in: 75...100, step: 1)
                        .fixedSize()
                }
                Text("High temperature, severe thermal pressure, or loss of die sensors raises fan demand to 100%. It does not hand control back to a quieter profile. Cooling eases only after a 3°C drop.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply profile settings") { Task { await model.apply() } }.disabled(model.busy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Control & recovery").font(.headline)
                Text("Automatic control is restored on quit, disconnect, or a stalled app. Hardware firmware can still reject an override; Breeze reports that separately. RPM always stays within the Mac’s reported limits.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Return to Automatic") { Task { await model.automatic() } }.disabled(model.busy)
                    if model.enabled { Button("Disconnect helper") { Task { await model.disable() } }.disabled(model.busy) }
                }
            }
        }.toggleStyle(.switch)
    }
    private func addCurvePoint() {
        let points = model.configuration.points.sorted { $0.temperature < $1.temperature }
        guard points.count >= 2 else { model.configuration.points = CoolingConfiguration().points; return }
        let gap = (0..<(points.count-1)).max { points[$0+1].temperature-points[$0].temperature < points[$1+1].temperature-points[$1].temperature } ?? 0
        var next = points
        next.insert(CurvePoint(temperature: (points[gap].temperature+points[gap+1].temperature)/2,
                               percent: (points[gap].percent+points[gap+1].percent)/2), at: gap+1)
        model.configuration.points = next
    }
    private func degrees(_ value: Double?) -> String { value.map { "\(Int($0))°C" } ?? "—" }
    private func gib(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes)/1_073_741_824) }
    private func notice(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(color)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
