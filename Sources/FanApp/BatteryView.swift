import AppKit
import FanCore
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
            HStack {
                Text("MagSafe light")
                Spacer()
                Picker("MagSafe light", selection: $app.charge.magSafeLED) {
                    Text("Automatic").tag(MagSafeLED?.none)
                    ForEach(MagSafeLED.allCases, id: \.self) { Text($0.name).tag(MagSafeLED?.some($0)) }
                }.labelsHidden().fixedSize()
                    .help("Overrides the MagSafe 3 connector light while Breeze is open. Automatic returns it to macOS.")
            }.font(.subheadline)
            if let status = app.magSafeStatus {
                Text(status).font(.caption).foregroundStyle(.orange).transition(.breezeFade)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(app.chargeStatus ?? (app.charge.isActive ? "Apply to start the charge limiter." : "macOS manages charging."))
                    .font(.caption).foregroundStyle(app.chargeStatus == nil ? .secondary : accent)
                Spacer()
                Button(app.charge.needsHelper ? "Apply" : "Return charging to macOS") { Task { await app.applyCharge() } }
                    .breezeAction(prominent: app.charge.needsHelper).disabled(app.busy)
            }
            Text("Holding a battery below 100% while plugged in reduces wear. Breeze pauses charging through the approved helper; your Mac keeps running on adapter power. On macOS 27 firmware that reserves charge control for Apple, Breeze instead disconnects the adapter at the limit and reconnects it below the sailing range, so the Mac runs on its battery in between; it never does this with the lid closed, and sleep pause isn't available there. The limit applies while Breeze is open: quitting, disconnecting the helper or restarting returns charging and the adapter to macOS. If the battery reading is unavailable, charging is allowed. macOS 26.4 and later also offers its own 80–100% limit in System Settings; turn one off if you use the other.")
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

/// Integrates TimelineView dates into flow distance and running time; never written to observable state.
private final class FlowBox {
    private var last: Date?
    /// Signed points travelled along the power path.
    private(set) var phase = 0.0
    /// Seconds of motion, always forward.
    private(set) var clock = 0.0
    /// `clock` when the charger was last connected.
    var surge = -10.0
    func advance(to date: Date, running: Bool, velocity: Double) {
        defer { last = date }
        guard running, let last else { return }
        let step = min(max(date.timeIntervalSince(last), 0), 0.25)
        phase += velocity * step
        clock += step
    }
}

/// Battery drawn at its value (never from 0) as a glass cell holding liquid charge, with a tick at
/// the charge limit and a cable at the terminal. While power flows it takes one path: pulses run
/// along the cable, pass the terminal, cross the empty part as droplets and merge into the fill,
/// which swells to take them. Discharging runs the same path backwards. All of it is faster with
/// more watts. Hovering tilts the cell toward the pointer and wakes the liquid. Colour means
/// charge only; the terminal and halo glow mint while charging.
private struct ChargeVessel: View {
    let percent: Double?
    let limit: Double?
    let watts: Double?
    @State private var flow = FlowBox()
    @State private var pointer: CGPoint?
    @Environment(\.breezeMotionLevel) private var level
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }
    private var low: Bool { (percent ?? 100) <= 20 }
    /// 1 charging, -1 discharging, 0 under 1 W.
    private var direction: Double {
        guard let watts, abs(watts) >= 1 else { return 0 }
        return watts > 0 ? 1 : -1
    }
    private var power: Double { min(abs(watts ?? 0), 100) }
    private var lively: Bool { !reduceMotion && level.isActive }
    private var hover: CGPoint? { lively ? pointer : nil }
    private var animating: Bool { lively && (direction != 0 || pointer != nil) }

    var body: some View {
        let size = VesselFrame.size
        // -0.5...0.5 from the centre; zero when the pointer is away.
        let lean = hover.map { CGPoint(x: $0.x / size.width - 0.5, y: $0.y / size.height - 0.5) } ?? .zero
        // One timeline keeps view identity stable when flow starts or stops.
        return TimelineView(.animation(minimumInterval: level.interval(fps: 30), paused: !animating)) { timeline in
            let _ = flow.advance(to: timeline.date, running: animating, velocity: direction * (14 + power * 0.5))
            VesselCanvas(frame: VesselFrame(
                fraction: fraction, limit: limit.map { min(max($0 / 100, 0), 1) },
                tint: low ? .orange : BreezeStyle.mint, direction: direction, moving: animating,
                phase: flow.phase, clock: flow.clock, surge: flow.clock - flow.surge,
                pointer: hover, reduceMotion: reduceMotion))
                .animation(BreezeMotion.animation(.drift, reduceMotion: reduceMotion), value: fraction)
        }
        .frame(width: size.width, height: size.height)
        .onContinuousHover { phase in
            if case .active(let point) = phase { pointer = point } else { pointer = nil }
        }
        .rotation3DEffect(.degrees(lean.x * 16), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(lean.y * -16), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .scaleEffect(hover == nil ? 1 : 1.04)
        .animation(BreezeMotion.animation(.lift, reduceMotion: reduceMotion), value: hover)
        // The halo's room is drawing space, not layout.
        .padding(-VesselFrame.pad)
        .onChange(of: direction) { old, new in
            if new > 0, old <= 0 { flow.surge = flow.clock }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery charge")
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent" } ?? "Unavailable")
    }
}

/// Hosts `VesselFrame`. Only the fill fraction animates, so per-frame values never get interpolated.
private struct VesselCanvas: View, Animatable {
    var frame: VesselFrame
    nonisolated var animatableData: Double {
        get { frame.fraction }
        set { frame.fraction = newValue }
    }
    var body: some View {
        let frame = frame
        Canvas { context, _ in frame.draw(&context) }
    }
}

/// One frame of the battery: a pure function of these values.
private struct VesselFrame: Sendable {
    static let pad = 14.0
    static let size = CGSize(width: 159 + pad * 2, height: 58 + pad * 2)
    private static let shell = CGRect(x: pad, y: pad, width: 120, height: 58)
    private static let inner = shell.insetBy(dx: 4, dy: 4)
    private static let terminal = CGRect(x: shell.maxX + 2, y: shell.midY - 11, width: 5, height: 22)
    private static let cableStart = terminal.maxX + 2
    private static let cableEnd = cableStart + 30
    /// Distance between two riders on the power path.
    private static let spacing = 36.0

    var fraction: Double
    var limit: Double?
    var tint: Color
    var direction: Double
    var moving: Bool
    var phase: Double
    var clock: Double
    /// Seconds since the charger was connected.
    var surge: Double
    var pointer: CGPoint?
    var reduceMotion: Bool

    /// Stable 0...1 variety per rider or bubble.
    private func noise(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }

    /// Everything riding the power path. A growing phase moves riders toward the leading side;
    /// the index stays with a rider for its whole trip.
    private func riders() -> [(x: Double, id: Int)] {
        guard moving, direction != 0 else { return [] }
        let low = ((Self.inner.minX - 60 - Self.cableEnd + phase) / Self.spacing).rounded(.up)
        let high = ((phase + 6) / Self.spacing).rounded(.down)
        guard low <= high else { return [] }
        return (Int(low)...Int(high)).map { (Self.cableEnd + Double($0) * Self.spacing - phase, $0) }
    }

    func draw(_ context: inout GraphicsContext) {
        let shell = Self.shell, inner = Self.inner, terminal = Self.terminal
        let innerPath = Path(roundedRect: inner, cornerRadius: 9)
        let white = Color.white
        let edge = inner.minX + inner.width * fraction
        let charging = moving && direction > 0
        let riders = riders()
        // Droplets grow out of the terminal wall and bob a little on the way over.
        let drops = riders.filter { $0.x > edge - 8 && $0.x < inner.maxX + 6 }.map { rider in
            (x: rider.x,
             y: inner.midY + (noise(rider.id, 2) - 0.5) * 20 + sin(clock * 2 + Double(rider.id)) * 1.5,
             radius: (5.2 + 1.6 * noise(rider.id, 1)) * min(1, (inner.maxX + 6 - rider.x) / 12))
        }
        // 0...1: how close a rider is to the charge edge, and to the terminal.
        let landing = riders.map { exp(-abs($0.x - edge) / 9) }.max() ?? 0
        let passing = riders.map { exp(-abs($0.x - terminal.midX) / 6) }.max() ?? 0
        // 1 falling to 0 over the moment after the charger connects.
        let welcome = charging ? max(0, 1 - surge / 0.9) : 0

        if charging, fraction > 0 {
            var halo = context
            // Outside the cell only, so the empty part stays clear.
            var outside = Path(CGRect(origin: .zero, size: Self.size))
            outside.addPath(innerPath)
            halo.clip(to: outside, style: FillStyle(eoFill: true))
            halo.addFilter(.blur(radius: 9))
            halo.opacity = min(1, 0.26 + 0.2 * landing + 0.4 * welcome)
            halo.fill(Path(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: edge - inner.minX, height: inner.height),
                           cornerRadius: 9), with: .color(tint))
        }
        context.fill(innerPath, with: .color(.primary.opacity(0.06)))
        if !drops.isEmpty {
            // A short wake behind each droplet.
            var wake = context
            wake.clip(to: innerPath)
            wake.addFilter(.blur(radius: 2))
            for drop in drops where drop.x > edge {
                let tail = drop.x + direction * 20
                wake.fill(Path(CGRect(x: min(drop.x, tail), y: drop.y - drop.radius * 0.45, width: 20, height: drop.radius * 0.9)),
                          with: .linearGradient(Gradient(colors: [tint.opacity(0.4), tint.opacity(0)]),
                                                startPoint: CGPoint(x: drop.x, y: 0), endPoint: CGPoint(x: tail, y: 0)))
            }
        }

        if fraction > 0 {
            var liquid = context
            liquid.clip(to: innerPath)
            // Blur then threshold fuses nearby shapes, so a droplet stretches into the fill as it lands.
            liquid.clipToLayer { layer in
                layer.addFilter(.alphaThreshold(min: 0.5))
                layer.addFilter(.blur(radius: 3))
                layer.drawLayer { goo in
                    goo.fill(surface(edge: edge, swell: landing), with: .color(white))
                    for drop in drops {
                        goo.fill(Path(ellipseIn: CGRect(x: drop.x - drop.radius * 1.2, y: drop.y - drop.radius * 0.92,
                                                        width: drop.radius * 2.4, height: drop.radius * 1.84)), with: .color(white))
                    }
                }
            }
            let body = Path(inner)
            liquid.fill(body, with: .color(tint))
            liquid.fill(body, with: .linearGradient(
                Gradient(stops: [.init(color: white.opacity(0.24), location: 0), .init(color: white.opacity(0), location: 0.45),
                                 .init(color: Color.black.opacity(0), location: 0.55), .init(color: Color.black.opacity(0.16), location: 1)]),
                startPoint: CGPoint(x: 0, y: inner.minY), endPoint: CGPoint(x: 0, y: inner.maxY)))
            if moving {
                // Light gathers at the surface and in the droplets beyond it.
                liquid.fill(Path(CGRect(x: edge - 30, y: inner.minY, width: 30, height: inner.height)), with: .linearGradient(
                    Gradient(colors: [white.opacity(0), white.opacity(0.1 + 0.22 * landing)]),
                    startPoint: CGPoint(x: edge - 30, y: 0), endPoint: CGPoint(x: edge, y: 0)))
                liquid.fill(Path(CGRect(x: edge, y: inner.minY, width: inner.maxX - edge, height: inner.height)),
                            with: .color(white.opacity(0.2)))
                for drop in drops where drop.x > edge + 4 {
                    let glint = drop.radius * 0.26
                    liquid.fill(Path(ellipseIn: CGRect(x: drop.x - drop.radius * 0.45 - glint, y: drop.y - drop.radius * 0.38 - glint,
                                                       width: glint * 2, height: glint * 2)), with: .color(white.opacity(0.65)))
                }
                // What landed keeps travelling into the fill and fades.
                for rider in riders where rider.x < edge {
                    band(&liquid, at: rider.x, width: 36, strength: 0.2 * max(0, 1 - (edge - rider.x) / 46))
                }
                let span = max(edge - inner.minX, 1)
                for index in 0..<9 {
                    let travel = (noise(index, 3) * span + phase * (0.25 + 0.45 * noise(index, 4))).truncatingRemainder(dividingBy: span)
                    let x = inner.minX + (travel < 0 ? travel + span : travel)
                    let y = inner.minY + 6 + noise(index, 5) * (inner.height - 12) + sin(clock * 1.4 + Double(index)) * 1.6
                    let radius = 0.8 + noise(index, 6) * 1.1
                    let fade = min(1, (edge - x) / 8, (x - inner.minX) / 8)
                    liquid.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                                with: .color(white.opacity(0.3 * max(0, fade))))
                }
                if welcome > 0 {
                    let progress = 1 - welcome * welcome
                    band(&liquid, at: inner.maxX + 20 - (inner.width + 40) * progress, width: 44, strength: 0.55 * welcome)
                }
            }
        }

        var glass = context
        glass.clip(to: innerPath)
        if let limit {
            glass.fill(Path(CGRect(x: inner.minX + limit * inner.width - 2, y: inner.minY, width: 2, height: inner.height)),
                       with: .color(.primary.opacity(0.6)))
        }
        glass.fill(Path(roundedRect: CGRect(x: inner.minX + 5, y: inner.minY + 3, width: inner.width - 10, height: 15), cornerRadius: 7),
                   with: .linearGradient(Gradient(colors: [white.opacity(0.16), white.opacity(0)]),
                                         startPoint: CGPoint(x: 0, y: inner.minY + 3), endPoint: CGPoint(x: 0, y: inner.minY + 18)))
        if let pointer {
            var spot = context
            spot.clip(to: Path(roundedRect: shell, cornerRadius: 13))
            spot.fill(Path(shell), with: .radialGradient(Gradient(colors: [white.opacity(0.24), white.opacity(0)]),
                                                         center: pointer, startRadius: 0, endRadius: 48))
        }
        context.stroke(Path(roundedRect: shell.insetBy(dx: 1, dy: 1), cornerRadius: 12),
                       with: .color(.primary.opacity(0.35)), lineWidth: 2)

        let cap = Path(roundedRect: terminal, cornerRadius: 2.5)
        if charging {
            var glow = context
            glow.addFilter(.blur(radius: 5))
            glow.opacity = min(1, 0.25 + 0.6 * passing + 0.4 * welcome)
            glow.fill(cap, with: .color(BreezeStyle.mint))
        }
        context.fill(cap, with: .color(direction > 0 ? BreezeStyle.mint.opacity(0.8) : .primary.opacity(0.35)))
        if charging { context.fill(cap, with: .color(white.opacity(0.6 * passing))) }

        guard direction != 0 else { return }
        let y = shell.midY
        if reduceMotion {
            context.draw(Text(Image(systemName: direction > 0 ? "chevron.left.2" : "chevron.right.2"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary),
                         at: CGPoint(x: Self.cableStart + 12, y: y))
            return
        }
        var line = Path()
        line.move(to: CGPoint(x: Self.cableStart, y: y))
        line.addLine(to: CGPoint(x: Self.cableEnd, y: y))
        context.stroke(line, with: .linearGradient(Gradient(colors: [.primary.opacity(0.4), .primary.opacity(0)]),
                                                   startPoint: CGPoint(x: Self.cableStart, y: y), endPoint: CGPoint(x: Self.cableEnd, y: y)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        for rider in riders where rider.x > Self.cableStart && rider.x < Self.cableEnd {
            var pulse = Path()
            pulse.move(to: CGPoint(x: max(rider.x - 5, Self.cableStart), y: y))
            pulse.addLine(to: CGPoint(x: min(rider.x + 5, Self.cableEnd), y: y))
            var comet = context
            comet.opacity = min(1, (Self.cableEnd - rider.x) / 10)
            let colour = direction > 0 ? BreezeStyle.mint : Color.primary.opacity(0.7)
            var glow = comet
            glow.addFilter(.blur(radius: 3))
            glow.stroke(pulse, with: .color(colour), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            comet.stroke(pulse, with: .color(colour), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    /// The fill, overdrawn past the cell so only its leading edge is ever soft. The edge carries two
    /// small travelling waves that grow for a moment when a droplet lands.
    private func surface(edge: Double, swell: Double) -> Path {
        let inner = Self.inner
        // Calms as the cell fills, so a full battery has no gap at the wall.
        let room = min(1, max(0, inner.maxX - edge) / 6)
        let amplitude = moving ? (direction == 0 ? 0.9 : 1.3) * (1 + 1.2 * swell) * room : 0
        var path = Path()
        path.move(to: CGPoint(x: inner.minX - 20, y: inner.minY - 12))
        for y in stride(from: inner.minY - 12, through: inner.maxY + 12, by: 2) {
            let wave = sin(y * 0.16 + clock * 2.6) + 0.55 * sin(y * 0.31 - clock * 3.7 + 1.3)
            path.addLine(to: CGPoint(x: edge + amplitude * wave, y: y))
        }
        path.addLine(to: CGPoint(x: inner.minX - 20, y: inner.maxY + 12))
        path.closeSubpath()
        return path
    }

    /// A soft vertical band of light centred on `x`.
    private func band(_ context: inout GraphicsContext, at x: Double, width: Double, strength: Double) {
        let inner = Self.inner
        context.fill(Path(CGRect(x: x - width / 2, y: inner.minY, width: width, height: inner.height)), with: .linearGradient(
            Gradient(colors: [Color.white.opacity(0), Color.white.opacity(strength), Color.white.opacity(0)]),
            startPoint: CGPoint(x: x - width / 2, y: 0), endPoint: CGPoint(x: x + width / 2, y: 0)))
    }
}
