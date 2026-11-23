import AppKit
import SwiftUI

struct BatteryView: View {
    @Bindable var model: BatteryModel
    @Bindable var app: AppModel
    private let accent = BreezeStyle.mint
    @State private var scrolled = false
    @State private var refreshCount = 0
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Keys the loading to content swap so every state change is one fade.
    private var phase: Int {
        guard let reading = model.reading else { return 0 }
        switch reading.availability {
        case .available: return 1
        case .noBattery: return 2
        case .unavailable: return 3
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            BreezePageHeader("Battery", subtitle: "Charge, health, and the power coming in.", scrolled: scrolled) {
                // Reserved slot: the spinner only appears after 0.3 s and never shifts the button.
                ZStack { if model.loading { BreezeDelayedProgress().controlSize(.small) } }.frame(width: 16, height: 16)
                Button { refreshCount += 1; Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").symbolEffect(.bounce, value: reduceMotion ? 0 : refreshCount)
                }.breezeAction(size: .regular).disabled(model.loading)
                    .help("Refresh battery details").accessibilityLabel("Refresh battery details")
            }
            Group {
            if let reading = model.reading {
                switch reading.availability {
                case .available:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            overview(reading)
                            chargeLimit
                            HStack(alignment: .top, spacing: 12) {
                                metric(0, reading.reportedHealthPercent == nil ? "ESTIMATED HEALTH" : "BATTERY HEALTH",
                                       value: number(reading.healthPercent, unit: "%", decimals: 0),
                                       detail: reading.reportedHealthPercent == nil ? "Capacity compared with design" : "macOS maximum capacity")
                                metric(1, "CYCLE COUNT", value: reading.cycles.map(String.init) ?? "Unavailable",
                                       detail: "Cumulative full charge cycles")
                                metric(2, reading.timeTitle, value: reading.timeLabel,
                                       detail: "macOS estimate · varies with use")
                            }
                            section("Power flow", symbol: "bolt") {
                                row("Drawing power from", reading.runningOnBattery.map { $0 ? "Battery" : "Power adapter" })
                                if reading.externalConnected == true {
                                    row("Power from adapter", number(reading.adapterInputWatts, unit: " W"))
                                }
                                row("Battery charge / discharge", reading.batteryFlowLabel)
                                Text("An idle battery uses 0 W while the adapter powers your Mac. Power from adapter is the live input at the Mac, including charging when active; it excludes losses in the charger.")
                                    .font(.caption).foregroundStyle(.secondary).padding(14)
                            }
                            section("Battery health", symbol: "heart") {
                                row("Condition", reading.condition)
                                row("Design capacity", number(reading.designCapacity, unit: " mAh", decimals: 0))
                                row("Full charge capacity", number(reading.fullChargeCapacity, unit: " mAh", decimals: 0))
                                row("Remaining charge", number(reading.remainingCapacity, unit: " mAh", decimals: 0))
                                row("Temperature", number(reading.temperature, unit: " °C"))
                                row("Device", reading.deviceName)
                                row("Serial number", reading.serialNumber)
                                row("Firmware", reading.firmware)
                            }
                            section("Electrical details", symbol: "waveform.path") {
                                row("External power connected", yesNo(reading.externalConnected))
                                row("Charging", yesNo(reading.charging))
                                row("Fully charged", yesNo(reading.fullyCharged))
                                row("Battery voltage", number(reading.voltage, unit: " V", decimals: 2))
                                row("Battery current", number(reading.amperage, unit: " mA", decimals: 0))
                                if reading.externalConnected == true {
                                    row("Live adapter input voltage", number(reading.adapterInputVoltage, unit: " V", decimals: 2))
                                    row("Live adapter input current", number(reading.adapterInputCurrent, unit: " A", decimals: 2))
                                }
                            }
                            Text("Positive battery current means charging; negative means discharging. Adapter input telemetry is available on supported Macs; missing readings show as unavailable.")
                                .font(.caption).foregroundStyle(.secondary)
                            charger(reading)
                            devices
                            Text(reading.reportedHealthPercent == nil
                                 ? "Health is estimated from nominal capacity (or full charge capacity when unavailable) divided by design capacity. It can differ from Battery Health in System Settings. Unsupported readings are shown as unavailable."
                                 : "Battery health is the maximum capacity reported by macOS. Health and battery identity refresh once a minute; live power readings refresh every five seconds. Unsupported readings are shown as unavailable.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, BreezeStyle.pagePadding).padding(.bottom, 24).breezeScrollEdge($scrolled)
                    }.transition(.breezeFade)
                case .noBattery:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ContentUnavailableView("No built-in battery", systemImage: "desktopcomputer",
                                                   description: Text("This Mac does not report an installed internal battery."))
                            devices
                        }.padding(.horizontal, BreezeStyle.pagePadding).padding(.bottom, 24).breezeScrollEdge($scrolled)
                    }.transition(.breezeFade)
                case .unavailable:
                    ContentUnavailableView("Battery readings unavailable", systemImage: "battery.0percent",
                                           description: Text("macOS could not provide battery details. Try refreshing."))
                        .transition(.breezeFade)
                }
            } else {
                VStack { Spacer(); BreezeDelayedProgress("Reading battery details…"); Spacer() }
                    .frame(maxWidth: .infinity).transition(.breezeFade)
            }
            }.breezeAnimation(.settle, value: phase)
            Divider()
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text("Updates every 5 seconds while this tab is open")
                Spacer()
                if let date = model.reading?.date {
                    Text("Updated \(date.formatted(date: .omitted, time: .standard))").breezeLive()
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 28).frame(height: 42)
        }
        .task { await model.run() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private func overview(_ reading: BatteryReading) -> some View {
        HStack(spacing: 22) {
            ChargeVessel(percent: reading.percent, limit: app.charge.enabled ? app.charge.limit : nil,
                         watts: reading.batteryWatts)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(number(reading.percent, unit: "%", decimals: 0))
                        .font(BreezeStyle.Typography.display).breezeLive()
                    Text(reading.status).font(.system(size: 14, weight: .medium))
                }
                if reading.externalConnected == true, reading.charging == false, reading.fullyCharged != true {
                    Text("macOS or battery management may be holding the charge, or available power may be limited.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .breezeSurface()
    }

    private var chargeLimit: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Charge limit", systemImage: "battery.100percent.circle").font(.headline)
                Spacer()
                if app.chargingPaused {
                    Text("CHARGING PAUSED").font(.system(size: 8, weight: .semibold)).foregroundStyle(accent)
                        .padding(5).background(accent.opacity(0.12), in: Capsule())
                }
                Toggle("Charge limit", isOn: $app.charge.enabled).labelsHidden().toggleStyle(.switch)
            }
            HStack {
                Text("Stop charging at")
                Spacer()
                // Rolls for stepped changes; follows a drag 1:1 (motion.md section 3).
                Text("\(Int(app.charge.limit))%").font(.title3).breezeNumeric(dragging ? nil : app.charge.limit)
            }.font(.subheadline)
            Slider(value: $app.charge.limit, in: 50...100, step: 5, onEditingChanged: { dragging = $0 })
                .tint(accent).disabled(!app.charge.enabled)
                .accessibilityLabel("Charge limit")
            HStack {
                Text("Resume charging below \(Int(app.charge.limit - app.charge.sailing))%").font(.subheadline)
                Spacer()
                Stepper("Sailing range \(Int(app.charge.sailing))%", value: $app.charge.sailing, in: 0...20, step: 1).fixedSize()
            }.disabled(!app.charge.enabled)
            Toggle("Pause charging while the Mac sleeps", isOn: Binding(
                get: { app.charge.pauseDuringSleep ?? false }, set: { app.charge.pauseDuringSleep = $0 ? true : nil }))
                .toggleStyle(.switch).font(.subheadline).disabled(!app.charge.enabled)
                .help("Stops the battery charging past the limit overnight. Charging resumes after wake if it is below the limit.")
            Toggle("Discharge to the limit while plugged in (experimental)", isOn: Binding(
                get: { app.charge.discharge ?? false },
                set: { app.charge.discharge = $0 ? true : nil; if $0 { app.charge.topUp = nil } }))
                .toggleStyle(.switch).font(.subheadline).disabled(!app.charge.enabled)
                .help("Above the limit, the Mac runs from its battery with the adapter connected, then reconnects at the limit. Breeze turns this off if the firmware doesn’t confirm the change.")
            HStack {
                Text(app.charge.topUp == true ? "Topping up. The limit returns when you unplug." : "Need a full battery for a trip?")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(app.charge.topUp == true ? "End top up" : "Top up to 100%") { Task { await app.topUp(app.charge.topUp != true) } }
                    .breezeAction(size: .small).disabled(app.busy || !app.charge.enabled || app.charge.discharge == true)
            }
            Divider()
            HStack {
                Toggle("Heat protection: pause charging above", isOn: $app.charge.heatProtection).toggleStyle(.switch)
                Spacer()
                Stepper("\(Int(app.charge.heatLimit))°C", value: $app.charge.heatLimit, in: 30...45, step: 1)
                    .fixedSize().disabled(!app.charge.heatProtection)
            }.font(.subheadline)
            HStack(alignment: .firstTextBaseline) {
                Text(app.chargeStatus ?? (app.charge.isActive ? "Apply to start the charge limiter." : "macOS manages charging."))
                    .font(.caption).foregroundStyle(app.chargeStatus == nil ? .secondary : accent)
                Spacer()
                Button(app.charge.isActive ? "Apply" : "Return charging to macOS") { Task { await app.applyCharge() } }
                    .breezeAction(prominent: app.charge.isActive).disabled(app.busy)
            }
            Text("Holding a battery below 100% while plugged in reduces wear. Breeze pauses charging through the approved helper; your Mac keeps running on adapter power. The limit applies while Breeze is open: quitting, disconnecting the helper or restarting returns charging and the adapter to macOS. If the battery reading is unavailable, charging is allowed. macOS 26.4 and later also offers its own 80–100% limit in System Settings; turn one off if you use the other.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).breezeSurface()
    }

    private var devices: some View {
        section("Bluetooth devices", symbol: "dot.radiowaves.left.and.right") {
            let devices = app.deviceBatteries.devices
            if !app.deviceBatteries.needsAccess.isEmpty && !app.deviceBatteries.accessDismissed { logitechAccess }
            if devices.isEmpty {
                Text(app.deviceBatteries.updated == nil ? "Looking for connected devices…" :
                        app.deviceBatteries.failed ? "macOS could not list Bluetooth devices." : "No connected device reports a battery level.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(14)
            }
            ForEach(devices) { device in
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: device.symbol).foregroundStyle(accent).frame(width: 22)
                        Text(device.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(device.levels.map { ($0.label.isEmpty ? "" : "\($0.label) ") + "\($0.percent)%" }.joined(separator: " · "))
                            .font(.system(size: 12)).breezeLive()
                            .foregroundStyle((device.lowest ?? 100) <= 20 ? .orange : .primary)
                    }
                    BreezeMeter(fraction: device.lowest.map { Double($0) / 100 },
                                tint: (device.lowest ?? 100) <= 20 ? .orange : accent, height: 4)
                        .accessibilityHidden(true)
                }.padding(.horizontal, 14).padding(.vertical, 10).accessibilityElement(children: .combine)
            }
            Text("Levels come from macOS Bluetooth information and refresh every minute while this page is open. Many third-party devices don’t report a battery level.")
                .font(.caption).foregroundStyle(.secondary).padding(14)
            if !app.deviceBatteries.needsAccess.isEmpty && app.deviceBatteries.accessDismissed {
                Button("Show Logitech battery…") { app.deviceBatteries.accessDismissed = false }
                    .breezeAction(size: .small).padding([.horizontal, .bottom], 14)
            }
        }
    }

    /// Explains the Input Monitoring prompt in plain words before Breeze ever triggers it.
    private var logitechAccess: some View {
        let names = ListFormatter.localizedString(byJoining: app.deviceBatteries.needsAccess)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Breeze found your \(names)", systemImage: "computermouse").font(.system(size: 13, weight: .semibold))
            Text("Logitech doesn’t share battery levels with macOS, so Breeze has to ask the device directly. macOS only allows that with the **Input Monitoring** permission, and its prompt says Breeze wants to “receive keystrokes from any application”. That wording covers every app that talks to a mouse or keyboard.")
            Text("Breeze only asks the device for its battery level and name. It doesn’t read your typing, clicks or movement, and nothing leaves your Mac. Without the permission, everything else in Breeze works as usual.")
            if app.deviceBatteries.accessDenied {
                Text("Input Monitoring is off for Breeze. Turn on Breeze in System Settings → Privacy & Security → Input Monitoring. macOS may ask you to reopen Breeze.")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Not now") { app.deviceBatteries.accessDismissed = true }.breezeAction()
                if app.deviceBatteries.accessDenied {
                    Button("Open Privacy & Security") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }.breezeAction(prominent: true)
                } else {
                    Button("Continue") { app.deviceBatteries.requestAccess() }.breezeAction(prominent: true)
                }
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true).padding(14)
    }

    private func charger(_ reading: BatteryReading) -> some View {
        section("Charger", symbol: "powerplug") {
            if reading.externalConnected == true {
                if let adapter = reading.adapter {
                    row("Name", adapter.name)
                    row("Manufacturer", adapter.manufacturer)
                    row("Reported power rating", number(adapter.watts, unit: " W", decimals: 0))
                    row("Available adapter voltage", number(adapter.voltage, unit: " V", decimals: 2))
                    row("Available adapter current", number(adapter.current, unit: " A", decimals: 2))
                    row("Model / adapter ID", adapter.model)
                    row("Serial number", adapter.serial)
                    row("Firmware", adapter.firmware)
                } else {
                    Text("External power is connected, but macOS has not provided adapter details.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(14)
                }
                Text("These ratings describe available output. See Power flow for the live power entering your Mac.")
                    .font(.caption).foregroundStyle(.secondary).padding(14)
            } else {
                Text(reading.externalConnected == false ? "Connect a charger to see its details." : "Charger connection status is unavailable.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(14)
            }
        }
    }

    private func metric(_ index: Int, _ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(BreezeStyle.Typography.eyebrow).tracking(BreezeStyle.Typography.eyebrowTracking).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .light, design: .rounded)).breezeLive()
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .breezeSurface(radius: 18)
            .breezeReveal(index, key: "battery")
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .breezeSurface(radius: 18)
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value ?? "Unavailable").fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled).breezeLive()
        }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 10)
            .accessibilityElement(children: .combine)
    }

    private func number(_ value: Double?, unit: String, decimals: Int = 1) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(decimals))) + unit } ?? "Unavailable"
    }

    private func yesNo(_ value: Bool?) -> String? { value.map { $0 ? "Yes" : "No" } }
    private func batterySymbol(_ percent: Double?) -> String {
        guard let percent else { return "battery.0percent" }
        switch percent {
        case ..<12.5: return "battery.0percent"
        case ..<37.5: return "battery.25percent"
        case ..<62.5: return "battery.50percent"
        case ..<87.5: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Integrates signed distance from TimelineView dates; never written to observable state.
private final class FlowBox {
    private var last: Date?
    private(set) var phase = 0.0
    func advance(to date: Date, running: Bool, velocity: Double) {
        defer { last = date }
        guard running, let last else { return }
        phase += velocity * min(max(date.timeIntervalSince(last), 0), 0.25)
    }
}

/// Battery drawn at its value (never from 0), a tick at the charge limit, and a dashed path
/// that flows in while charging and out while discharging. Colour means charge only.
private struct ChargeVessel: View {
    let percent: Double?
    let limit: Double?
    let watts: Double?
    @State private var flow = FlowBox()
    @Environment(\.breezeMotionLevel) private var level
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let inner = CGSize(width: 112, height: 50)
    private var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }
    private var low: Bool { (percent ?? 100) <= 20 }
    /// 1 charging, -1 discharging, 0 under 1 W.
    private var direction: Double {
        guard let watts, abs(watts) >= 1 else { return 0 }
        return watts > 0 ? 1 : -1
    }

    var body: some View {
        HStack(spacing: 6) {
            flowPath.frame(width: 30, height: 20)
            vessel
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery charge")
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent" } ?? "Unavailable")
    }

    private var vessel: some View {
        HStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
                ZStack(alignment: .leading) {
                    Color.primary.opacity(0.06)
                    Rectangle().fill(low ? Color.orange : BreezeStyle.mint)
                        .animation(BreezeMotion.animation(.settle, reduceMotion: reduceMotion), value: low)
                        .scaleEffect(x: fraction, anchor: .leading)
                        .animation(BreezeMotion.animation(.drift, reduceMotion: reduceMotion), value: fraction)
                    if let limit {
                        // Follows the slider 1:1, so it is never animated.
                        Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2)
                            .offset(x: min(max(limit / 100, 0), 1) * inner.width - 2)
                    }
                }
                .frame(width: inner.width, height: inner.height)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }.frame(width: 120, height: 58)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.35)).frame(width: 5, height: 22)
        }
    }

    @ViewBuilder private var flowPath: some View {
        if direction == 0 {
            Color.clear
        } else if reduceMotion {
            Image(systemName: direction > 0 ? "chevron.right.2" : "chevron.left.2")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        } else {
            let running = level.isActive
            TimelineView(.animation(minimumInterval: level.interval(fps: 20), paused: !running)) { timeline in
                let speed = 8 + min(abs(watts ?? 0), 100) * 0.4
                let _ = flow.advance(to: timeline.date, running: running, velocity: direction * speed)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 10))
                    path.addLine(to: CGPoint(x: 30, y: 10))
                }
                .stroke(Color.primary.opacity(0.5), style: StrokeStyle(
                    lineWidth: 1.5, lineCap: .round, dash: [4, 5],
                    dashPhase: -flow.phase.truncatingRemainder(dividingBy: 9)))
                .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
            }
        }
    }
}
