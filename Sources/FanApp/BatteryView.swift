import AppKit
import SwiftUI

struct BatteryView: View {
    @Bindable var model: BatteryModel
    private let accent = Color(red: 0.22, green: 0.67, blue: 0.55)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Battery").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Charge, health, and the power coming in.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.breezeAction(size: .regular).disabled(model.loading)
                    .help("Refresh battery details").accessibilityLabel("Refresh battery details")
            }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 20)
            if let reading = model.reading {
                switch reading.availability {
                case .available:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            overview(reading)
                            HStack(alignment: .top, spacing: 12) {
                                metric(reading.reportedHealthPercent == nil ? "ESTIMATED HEALTH" : "BATTERY HEALTH",
                                       value: number(reading.healthPercent, unit: "%", decimals: 0),
                                       detail: reading.reportedHealthPercent == nil ? "Capacity compared with design" : "macOS maximum capacity")
                                metric("CYCLE COUNT", value: reading.cycles.map(String.init) ?? "Unavailable",
                                       detail: "Cumulative full charge cycles")
                                metric(reading.timeTitle, value: reading.timeLabel,
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
                            Text(reading.reportedHealthPercent == nil
                                 ? "Health is estimated from nominal capacity (or full charge capacity when unavailable) divided by design capacity. It can differ from Battery Health in System Settings. Unsupported readings are shown as unavailable."
                                 : "Battery health is the maximum capacity reported by macOS. Health and battery identity refresh once a minute; live power readings refresh every five seconds. Unsupported readings are shown as unavailable.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 28).padding(.bottom, 24)
                    }
                case .noBattery:
                    ContentUnavailableView("No built-in battery", systemImage: "desktopcomputer",
                                           description: Text("This Mac does not report an installed internal battery."))
                case .unavailable:
                    ContentUnavailableView("Battery readings unavailable", systemImage: "battery.0percent",
                                           description: Text("macOS could not provide battery details. Try refreshing."))
                }
            } else {
                Spacer()
                ProgressView("Reading battery details…")
                Spacer()
            }
            Divider()
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text("Updates every 5 seconds while this tab is open")
                Spacer()
                if let date = model.reading?.date {
                    Text("Updated \(date.formatted(date: .omitted, time: .standard))").monospacedDigit()
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
            Image(systemName: reading.charging == true ? "battery.100percent.bolt" : batterySymbol(reading.percent))
                .font(.system(size: 58, weight: .light))
                .foregroundStyle((reading.percent ?? 100) <= 20 ? .orange : accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(number(reading.percent, unit: "%", decimals: 0))
                        .font(.system(size: 42, weight: .light, design: .rounded)).monospacedDigit()
                    Text(reading.status).font(.system(size: 14, weight: .medium))
                }
                if let percent = reading.percent {
                    ProgressView(value: percent, total: 100)
                        .tint(accent).accessibilityLabel("Battery charge")
                        .accessibilityValue(number(percent, unit: "%", decimals: 0))
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

    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .light, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .breezeSurface(radius: 18)
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
            Text(value ?? "Unavailable").fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
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
