import Charts
import FanCore
import SwiftUI

struct Dashboard: View {
    @Bindable var model: AppModel
    @State private var exporting = false
    @State private var exportDocument = CoolingHistoryDocument(text: "")
    @State private var scrolled = false
    @State private var sliding = false
    @State private var connects = 0
    @State private var selections: [AppModel.Page: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let accent = BreezeStyle.mint

    var body: some View {
        BreezeGlassGroup(spacing: 8) {
            HStack(spacing: 12) {
                sidebar.breezeGlass(radius: 26).padding(.vertical, 12).padding(.leading, 12)
                BreezeSwitcher(model.page, index: AppModel.Page.allCases.firstIndex(of: model.page) ?? 0, axis: .vertical, token: .hover) {
                    content
                }
            }
        }
        .frame(minWidth: 1020, minHeight: 740)
        .background { BreezeBackdrop() }
        .background { pageShortcuts }
        .environment(\.breezeHeat, BreezeMotion.heat(temperature: model.snapshot?.hottest, boost: model.configuration.boostTemperature))
        .breezeMotionScope()
        .tint(accent)
        .breezeAction(size: .regular)
        .onChange(of: model.enabled) { _, enabled in if enabled { connects += 1 } }
        .onChange(of: model.page) { _, page in
            selections[page, default: 0] += 1
            scrolled = false
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "Breeze-cooling-history") { result in
            if case .failure(let error) = result { model.message = error.localizedDescription }
        }
    }

    /// Cmd-1 to Cmd-9 select the pages in sidebar order.
    private var pageShortcuts: some View {
        ZStack {
            // Only digits 1-9 exist; a tenth page must not form a two-character key equivalent.
            ForEach(Array(AppModel.Page.allCases.prefix(9).enumerated()), id: \.offset) { index, page in
                Button(page.rawValue) { model.page = page }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .focusable(false) // invisible: never a keyboard-navigation stop
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var symbolSwap: ContentTransition { reduceMotion ? .opacity : .symbolEffect(.replace) }

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
                    let selected = model.page == page
                    let storageBusy = page == .storage && model.storage.busy
                    HStack(spacing: 10) {
                        Label {
                            Text(page.rawValue)
                        } icon: {
                            Image(systemName: page.symbol)
                                .symbolVariant(selected ? .fill : .none)
                                .contentTransition(symbolSwap)
                                .symbolEffect(.bounce, value: reduceMotion ? 0 : selections[page, default: 0])
                        }
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if storageBusy { ProgressView().controlSize(.mini).transition(.breezeFade) }
                    }
                    .breezeAnimation(.settle, value: selected)
                    .breezeAnimation(.settle, value: storageBusy)
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
                    .contentTransition(.opacity)
                    .breezeAnimation(.settle, value: model.statusTitle)
                Text("\(model.rpmLabel) RPM").font(.system(size: 21, weight: .light, design: .rounded)).breezeLive()
                Text(model.boostRemaining.map { "Timed boost · \($0) left" } ?? "Live cooling status").font(.caption2).foregroundStyle(.secondary)
                    .breezeLive()
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
            BatteryView(model: model.battery, app: model)
        } else if model.page == .checkup {
            CheckupView(model: model)
        } else {
        VStack(spacing: 0) {
            BreezePageHeader(model.page.rawValue, subtitle: pageSubtitle, scrolled: scrolled) {
                Circle().fill(model.snapshot == nil ? .orange : accent).frame(width: 6, height: 6)
                    .breezeAnimation(.settle, value: model.snapshot == nil)
                    .breezePulse(trigger: connects)
                Text(model.enabled ? "Control connected" : "Monitoring").font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .breezeAnimation(.settle, value: model.enabled)
                Button { Task { await model.automatic() } } label: { Label("Automatic", systemImage: "arrow.uturn.backward") }
                    .breezeAction().disabled(model.busy || model.snapshot?.canControl != true)
                    .help("Return fan control to macOS")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.page == .overview { metrics.breezeReveal(0, key: "overview") } else if model.page != .settings { metrics }
                    if let error = model.readError { notice(error, color: .orange).transition(.breezeDrop) }
                    if let message = model.message { notice(message, color: .orange).transition(.breezeDrop) }
                    switch model.page {
                    case .overview: overview
                    case .cooling: cooling
                    case .statistics: statistics
                    case .settings: settings
                    case .storage, .network, .mac, .battery, .checkup: EmptyView()
                    }
                }
                .breezeAnimation(.settle, value: model.readError)
                .breezeAnimation(.settle, value: model.message)
                .padding(.horizontal, BreezeStyle.pagePadding).padding(.bottom, 20)
                .breezeScrollEdge($scrolled)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(accent)
                Text(model.statusDetail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.small).transition(.breezeFade) }
            }
            .breezeAnimation(.settle, value: model.statusDetail)
            .breezeAnimation(.settle, value: model.busy)
            .padding(.horizontal, BreezeStyle.pagePadding).frame(height: 54)
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
        case .checkup: "One look at everything that matters."
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            OverviewSummaryView(model: model).breezeReveal(0, key: "overview")
            temperatureChart.padding(20).breezeSurface().breezeReveal(1, key: "overview")
            HStack(spacing: 12) {
                destination(.battery, title: "Power, in perspective", detail: "Charge, battery health & live power flow.", color: accent)
                    .breezeReveal(2, key: "overview")
                destination(.network, title: "Know your connection", detail: "Traffic, internet quality & nearby devices.", color: BreezeStyle.blue)
                    .breezeReveal(3, key: "overview")
                destination(.storage, title: "Room for what’s next", detail: "Drive health, space maps & file cleanup.", color: .orange)
                    .breezeReveal(4, key: "overview")
            }
            fanList.padding(20).breezeSurface().breezeReveal(5, key: "overview")
        }
    }
    private func destination(_ page: AppModel.Page, title: String, detail: String, color: Color) -> some View {
        Button { model.page = page } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: page.symbol).font(.title2).foregroundStyle(color)
                    Spacer()
                    Image(systemName: "arrow.up.right").foregroundStyle(.tertiary).breezeNudge(x: 2, y: -2)
                }
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .breezeGlass(interactive: true)
        }.buttonStyle(.breezeCard)
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric("CPU die", value: degrees(model.snapshot?.cpuTemperature), symbol: "cpu", tint: thermalTint(model.snapshot?.cpuTemperature))
            metric("GPU die", value: degrees(model.snapshot?.gpuTemperature), symbol: "square.3.layers.3d", tint: thermalTint(model.snapshot?.gpuTemperature))
            metric("CPU load", value: model.systemStats?.cpuPercent.map { "\(Int($0))%" } ?? "—", symbol: "waveform.path")
            metric("Memory", value: model.systemStats.map { "\(gib($0.memoryUsed)) GB" } ?? "—", symbol: "memorychip")
        }
    }
    private func metric(_ title: String, value: String, symbol: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Image(systemName: symbol).font(.caption).foregroundStyle(tint ?? accent)
                    .breezeAnimation(.settle, value: tint)
            }
            Text(value).font(BreezeStyle.Typography.numeralL).breezeLive().lineLimit(1).minimumScaleFactor(0.7)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .breezeSurface()
    }
    private func thermalTint(_ temperature: Double?) -> Color {
        BreezeMotion.thermalColor(BreezeMotion.heat(temperature: temperature, boost: model.configuration.boostTemperature))
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
                BreezeSwitcher(model.configuration.mode, index: CoolingMode.allCases.firstIndex(of: model.configuration.mode) ?? 0) {
                    VStack(alignment: .leading, spacing: 16) { modeEditor }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text(model.helperStatus == .enabled ? "Apply changes to activate this profile." : "Approve the cooling helper once in Settings to enable fan control.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await model.apply() } } label: {
                        Text(model.busy ? "Applying…" : model.configuration.mode == .automatic ? "Use Automatic" : "Apply profile")
                            .contentTransition(.opacity)
                    }
                    .breezeAction(prominent: true).tint(accent)
                    .disabled(model.busy || model.snapshot?.canControl != true)
                    .breezeAnimation(.settle, value: model.busy)
                }
            }.padding(20).breezeSurface()
            CoolingAutomationView(model: model).padding(20).breezeSurface()
            fanList.padding(20).breezeSurface()
            temperatureChart.padding(20).breezeSurface()
        }
    }
    @ViewBuilder private var modeEditor: some View {
        // Slider numerals follow the thumb 1:1: no animation while it is being dragged.
        let dragging = sliding
        switch model.configuration.mode {
        case .automatic:
            Text("macOS chooses fan speeds. Select a custom profile or Maximum cooling to set your own targets.")
                .font(.caption).foregroundStyle(.secondary)
        case .manual:
            HStack {
                Text("Fixed speed").font(.subheadline)
                Spacer()
                Text("\(Int(model.configuration.manualPercent))%").font(.title3).breezeLive()
                    .transaction { if dragging { $0.animation = nil } }
            }
            Slider(value: $model.configuration.manualPercent, in: 0...100, step: 1, onEditingChanged: { sliding = $0 }).tint(accent)
                .accessibilityLabel("Fixed fan speed")
            HStack { Text("Hardware minimum"); Spacer(); Text("Hardware maximum") }.font(.caption2).foregroundStyle(.secondary)
            Text(fixedSpeedPreview).font(.caption).foregroundStyle(accent)
                .breezeNumeric(dragging ? nil : model.configuration.manualPercent)
        case .curve: curveEditor
        case .target:
            HStack(alignment: .firstTextBaseline) {
                Text("Aim to stay below").font(.subheadline)
                Spacer()
                Text("\(Int(model.configuration.targetTemperature))°C")
                    .font(.system(size: 32, weight: .light, design: .rounded)).breezeLive()
                    .foregroundStyle(thermalTint(model.configuration.targetTemperature))
                    .transaction { if dragging { $0.animation = nil } }
            }
            Slider(value: $model.configuration.targetTemperature, in: 40...90, step: 1, onEditingChanged: { sliding = $0 }).tint(accent)
                .accessibilityLabel("Target die temperature")
            sensorPicker
            Text("Fan speed adapts to the chosen sensors and how quickly they are heating up. Heat boost still watches the hottest die. If full fan speed cannot meet the target, Breeze will say so.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// nil keeps the hottest-die default, so unchanged profiles compare equal to saved ones.
    private var sensorPicker: some View {
        Picker("Follow", selection: Binding(get: { model.configuration.sensor ?? .hottest },
                                            set: { model.configuration.sensor = $0 == .hottest ? nil : $0 })) {
            ForEach(CoolingSensor.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).fixedSize().controlSize(.small)
        .help("Which die temperatures drive this profile. Without GPU readings, GPU falls back to the hottest die.")
    }
    private var curveEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fan speed by temperature").font(.subheadline)
                Spacer()
                Button("Balanced") { BreezeMotion.animate(.glide) { model.configuration.points = CoolingConfiguration().points } }
                Button("Performance") {
                    BreezeMotion.animate(.glide) {
                        model.configuration.points = [CurvePoint(temperature: 35, percent: 35), CurvePoint(temperature: 50, percent: 60),
                                                      CurvePoint(temperature: 60, percent: 85), CurvePoint(temperature: 70, percent: 100)]
                    }
                }
            }.controlSize(.small)
            sensorPicker
            CurveChart(configuration: model.configuration,
                       liveTemperature: model.snapshot.flatMap { (model.configuration.sensor ?? .hottest).temperature(in: $0) })
            VStack(alignment: .leading, spacing: 12) {
                ForEach($model.configuration.points) { $point in
                    let number = (model.configuration.points.firstIndex { $0.id == point.id } ?? 0) + 1
                    HStack(spacing: 10) {
                        Text("Point \(number)").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        TextField("Temperature", value: $point.temperature, format: .number.precision(.fractionLength(0)))
                            .frame(width: 64).accessibilityLabel("Point \(number) temperature")
                        Text("°C").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        TextField("Speed", value: $point.percent, format: .number.precision(.fractionLength(0)))
                            .frame(width: 64).accessibilityLabel("Point \(number) speed")
                        Text("%").font(.caption).foregroundStyle(.secondary)
                        Button { model.configuration.points.removeAll { $0.id == point.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.configuration.points.count <= 2)
                            .accessibilityLabel("Remove point \(number)")
                    }
                    .textFieldStyle(.roundedBorder)
                    .transition(.breezeDrop)
                }
            }
            .breezeAnimation(.settle, value: model.configuration.points.map(\.id))
            Button("Add curve point", systemImage: "plus") { addCurvePoint() }
                .disabled(model.configuration.points.count >= 12)
            Text("Temperatures must increase. Fan speeds can stay level or increase. The orange line is the live temperature of the followed sensors; heat boost always watches the hottest die.")
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
                            .contentTransition(.opacity)
                            .breezeAnimation(.settle, value: fan.isManual)
                        Spacer()
                        Text("\(Int(fan.current)) RPM").font(.system(size: 18, weight: .medium, design: .rounded)).breezeLive()
                    }
                    BreezeMeter(fraction: fan.current / max(1, fan.maximum), marker: fan.target.map { $0 / max(1, fan.maximum) })
                        .accessibilityLabel("\(fan.name) actual fan speed")
                    HStack {
                        Text("Range \(max(0, Int(fan.minimum)))–\(max(0, Int(fan.maximum))) RPM")
                        Spacer()
                        Text(fan.target.map { "Target \(Int($0)) RPM" } ?? "Target unavailable").breezeLive()
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
                Text("Peak \(degrees(model.visibleHistory.map(\.temperature).max()))").breezeLive()
                Text("Average \(degrees(historyAverage))").breezeLive()
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            HistoryPlot(samples: model.visibleHistory, value: \.temperature, label: "°C", format: { "\(Int($0))°C" },
                        drawKey: "\(model.page.rawValue).thermal", yDomain: 0...110, height: 115, area: true,
                        empty: "Collecting temperature readings…")
                .breezeAnimation(.settle, value: model.historySeconds)
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
                HistoryPlot(samples: model.history, value: \.rpm, label: "RPM", format: { "\(Int($0)) RPM" },
                            drawKey: "statistics.fanspeed", yDomain: AutomaticScaleDomain.automatic, height: 100)
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
                    Text("\(gib(stats.memoryUsed)) / \(gib(stats.memoryTotal)) GB").foregroundStyle(.secondary).breezeLive()
                }.font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Die sensors").font(.headline)
                Text("Raw sensor keys vary by Mac. Keys starting with Tg are GPU dies; profiles can follow the hottest die, CPU dies or GPU dies, and heat boost always uses the hottest.").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(model.snapshot?.temperatures ?? [], id: \.key) { sensor in
                        HStack {
                            Text(sensor.key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Text(degrees(sensor.celsius)).font(.caption).breezeLive()
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
            AlertSettingsView(alerts: model.alerts)
            Divider()
            AssistantSettingsView(cleanup: model.storage.cleanup)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Cooling helper").font(.headline)
                Label {
                    Text(model.helperStatus == .enabled ? "Approved · ready for fan control" : model.helperStatus == .requiresApproval ? "Waiting for approval in System Settings" : "One-time setup required")
                        .contentTransition(.opacity)
                } icon: {
                    Image(systemName: model.helperStatus == .enabled ? "checkmark.circle" : model.helperStatus == .requiresApproval ? "clock" : "circle.dashed")
                        .foregroundStyle(model.helperStatus == .enabled ? accent : Color.secondary)
                        .contentTransition(symbolSwap)
                }
                .font(.subheadline)
                Text("Approve Breeze’s background helper once. It handles fan changes on future launches without asking for your password each session. No password is saved.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.helperStatus == .enabled {
                        Group {
                            Button("Manage approval") { model.openHelperSettings() }
                            Button("Remove helper", role: .destructive) { Task { await model.removeHelper() } }
                        }.transition(.breezeFade)
                    } else {
                        Button(model.helperStatus == .requiresApproval ? "Open System Settings" : "Set up cooling helper") { model.setupHelper() }
                            .transition(.breezeFade)
                    }
                }.disabled(model.busy)
            }
            .breezeAnimation(.settle, value: model.helperStatus)
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
                    Stepper(value: $model.configuration.boostTemperature, in: 75...100, step: 1) {
                        Text("\(Int(model.configuration.boostTemperature))°C").breezeNumeric(model.configuration.boostTemperature)
                    }
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
                if model.charge.isActive {
                    Text("Disconnecting the helper also turns off the charge limit until Breeze reconnects.")
                        .font(.caption).foregroundStyle(.secondary)
                        .transition(.breezeDrop)
                }
                HStack {
                    Button("Return to Automatic") { Task { await model.automatic() } }.disabled(model.busy)
                    if model.enabled {
                        Button("Disconnect helper") { Task { await model.disable() } }.disabled(model.busy)
                            .transition(.breezeFade)
                    }
                }
            }
            .breezeAnimation(.settle, value: model.charge.isActive)
            .breezeAnimation(.settle, value: model.enabled)
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

/// A history line that draws in once per session and scrubs by hover or arrow keys. New samples are not animated.
private struct HistoryPlot<Domain: ScaleDomain>: View {
    let samples: [AppModel.Sample]
    let value: KeyPath<AppModel.Sample, Double>
    let label: String
    let format: (Double) -> String
    let drawKey: String
    let yDomain: Domain
    let height: CGFloat
    var area = false
    var empty: String?
    @State private var scrub: Date?

    var body: some View {
        let selected = scrub.flatMap { BreezeMotion.nearest(samples, to: $0, by: \.date) }
        let isEmpty = samples.isEmpty
        Chart {
            ForEach(samples) { sample in
                if area {
                    AreaMark(x: .value("Time", sample.date), yStart: .value("Baseline", 0), yEnd: .value(label, sample[keyPath: value]))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [BreezeStyle.mint.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                }
                LineMark(x: .value("Time", sample.date), y: .value(label, sample[keyPath: value]))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(BreezeStyle.mint)
            }
            if let selected {
                RuleMark(x: .value("Time", selected.date))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", selected.date), y: .value(label, selected[keyPath: value]))
                    .symbolSize(48)
                    .foregroundStyle(BreezeStyle.mint)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        BreezeChartCallout(title: selected.date.formatted(date: .omitted, time: .standard),
                                           value: format(selected[keyPath: value]))
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartPlotStyle { $0.breezeChartDrawIn(key: drawKey) }
        .breezeChartScrub($scrub)
        .breezeChartKeys($scrub, dates: samples.map(\.date))
        .frame(height: height)
        .overlay {
            ZStack {
                if let empty, isEmpty {
                    Text(empty).font(.caption).foregroundStyle(.secondary).transition(.breezeFade)
                }
            }
            .breezeAnimation(.settle, value: isEmpty)
        }
    }
}

/// The curve editor's chart: preset morphs animate (caller's transaction), the live marker drifts, hover and arrow keys read the curve.
private struct CurveChart: View {
    let configuration: CoolingConfiguration
    let liveTemperature: Double?
    @State private var scrub: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let points = configuration.points.sorted { $0.temperature < $1.temperature }
        Chart {
            // Keyed by position so Balanced and Performance morph the line instead of swapping it.
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("°C", point.temperature), y: .value("Speed %", point.percent)).foregroundStyle(BreezeStyle.mint)
                PointMark(x: .value("°C", point.temperature), y: .value("Speed %", point.percent)).foregroundStyle(BreezeStyle.mint)
            }
            if let scrub, let percent = try? configuration.curvePercent(at: scrub) {
                RuleMark(x: .value("Scrub", scrub))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("°C", scrub), y: .value("Speed %", percent))
                    .symbolSize(48)
                    .foregroundStyle(BreezeStyle.mint)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        BreezeChartCallout(title: "Curve", value: "\(Int(scrub))°C → \(Int(percent.rounded()))%")
                    }
            }
        }
        .chartXScale(domain: 20...110).chartYScale(domain: 0...100).frame(height: 115)
        .chartXAxisLabel("Die temperature, °C").chartYAxisLabel("Fan %")
        .chartOverlay { proxy in liveMarker(proxy) }
        .chartOverlay { proxy in hover(proxy) }
        .focusable(interactions: .activate)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.escape) {
            guard scrub != nil else { return .ignored }
            scrub = nil
            return .handled
        }
    }

    /// The orange live-temperature rule and a point riding the curve. Only these follow the sample with `drift`.
    private func liveMarker(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let temperature = liveTemperature, (20...110).contains(temperature),
               let frame = proxy.plotFrame, let x = proxy.position(forX: temperature) {
                let plot = geo[frame]
                ZStack {
                    VerticalRule()
                        .stroke(.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: 1, height: plot.height)
                        .position(x: plot.minX + x, y: plot.midY)
                    if let percent = try? configuration.curvePercent(at: temperature), let y = proxy.position(forY: percent) {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                            .position(x: plot.minX + x, y: plot.minY + y)
                    }
                }
                .animation(reduceMotion ? nil : BreezeMotion.animation(.drift, reduceMotion: false), value: temperature)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func hover(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let point) = phase, let frame = proxy.plotFrame else {
                        scrub = nil
                        return
                    }
                    let plot = geo[frame]
                    scrub = proxy.value(atX: min(max(point.x - plot.minX, 0), plot.width), as: Double.self)?.rounded()
                }
        }
    }

    private func step(_ delta: Double) -> KeyPress.Result {
        scrub = min(max((scrub ?? liveTemperature ?? 60).rounded() + delta, 20), 110)
        return .handled
    }
}

private struct VerticalRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

/// Same stored values as Cleanup & apps → AI options, so both places stay in sync.
private struct AssistantSettingsView: View {
    let cleanup: StorageCleanupModel
    @AppStorage("cleanupAssistantClient") private var client = "codex"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI assistant").font(.headline)
            Picker("Assistant for Ask AI", selection: $client) {
                ForEach(CleanupAssistantClient.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
            }.pickerStyle(.segmented).fixedSize().disabled(cleanup.assistantRunning)
            if let selected = CleanupAssistantClient(rawValue: client) {
                if let executable = selected.executable {
                    Label("\(selected.name) is installed", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(BreezeStyle.mint).help(executable.path)
                } else {
                    Label("Install \(selected.name)'s official CLI and sign in from Terminal once.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Share cleanup metadata with my assistant", isOn: Binding(
                get: { cleanup.assistantSharing }, set: { cleanup.setAssistantSharing($0) }))
                .disabled(cleanup.cleaning)
            Text("Ask AI in Cleanup & apps uses this assistant with your CLI's own sign-in. It shares item names, sizes, dates and shortened paths, never file contents. You approve every removal in Breeze.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
