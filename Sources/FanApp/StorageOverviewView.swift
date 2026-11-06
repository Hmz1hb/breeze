import AppKit
import Charts
import StorageCore
import SwiftUI

private let diskMint = Color(red: 0.22, green: 0.67, blue: 0.55)
private let diskWrite = Color(red: 0.40, green: 0.53, blue: 0.82)

private func diskSize(_ bytes: Int64) -> String {
    if bytes == 0 { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
}
private func diskRate(_ value: Double?) -> String {
    guard let value else { return "—" }
    return diskSize(Int64(min(Double(Int64.max - 1024), max(0, value)))) + "/s"
}

// Intent: a Mac owner checking space, load and drive condition in one quiet view.
// Domain: breathing room, mounted volumes, shared containers, transfers, endurance.
// Palette: graphite text, aluminum surfaces, mint reads, slate-blue writes, amber warnings.
// Signature: a bank of capacity ticks echoes Breeze's breathing-room language.
// A volume rail replaces the reference's disk rows; positive traces replace the
// mirrored graph; a health summary and expandable passport replace dense tables.
// Depth: subtle surface shifts and fine borders. SF rounded headings, tabular
// measurements and a four-point spacing grid match the rest of Breeze.
struct StorageOverviewView: View {
    @Bindable var monitor: StorageMonitor

    var body: some View {
        Group {
            if monitor.loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Getting to know your drives…").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if monitor.drives.isEmpty {
                ContentUnavailableView("No local volumes available", systemImage: "internaldrive",
                                       description: Text("Mounted local volumes will appear here automatically."))
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 20) {
                        volumeRail.frame(width: 192)
                        if let drive = monitor.selected {
                            VStack(alignment: .leading, spacing: 16) {
                                capacity(drive)
                                activity(drive)
                                health(drive)
                                deviceDetails(drive)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }
            }
        }
        Divider()
        HStack(spacing: 8) {
            Image(systemName: "waveform.path").foregroundStyle(diskMint)
            Text("Activity every 2s · drive details every 30s").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("Read-only monitoring").font(.caption2).foregroundStyle(.tertiary)
        }.padding(.horizontal, 28).frame(height: 44)
    }

    private var volumeRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("VOLUMES").font(.system(size: 10, weight: .semibold)).tracking(1.3)
                Spacer()
                Text(monitor.drives.count.formatted()).font(.caption.monospacedDigit())
            }.foregroundStyle(.secondary).padding(.horizontal, 4).padding(.bottom, 4)
            ForEach(monitor.drives) { drive in
                Button { monitor.selectedID = drive.id } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: drive.isInternal ? "internaldrive" : "externaldrive")
                                .font(.system(size: 20, weight: .light)).foregroundStyle(diskMint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(drive.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                Text(drive.isStartup ? "Startup disk" : drive.isInternal ? "Internal volume" : "External volume")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        GeometryReader { geometry in
                            Capsule().fill(.primary.opacity(0.07))
                            Capsule().fill(drive.usedFraction >= 0.9 ? Color.orange : diskMint.opacity(0.7))
                                .frame(width: geometry.size.width * drive.usedFraction)
                        }.frame(height: 3)
                        Text("\(diskSize(drive.free)) free").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(monitor.selectedID == drive.id ? diskMint.opacity(0.09) : Color.primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(monitor.selectedID == drive.id ? diskMint.opacity(0.45) : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(monitor.selectedID == drive.id ? .isSelected : [])
                    .accessibilityLabel("\(drive.name), \(diskSize(drive.free)) free, \(Int(drive.usedFraction * 100)) percent used")
            }
            Label("APFS volumes can share the same free space. Capacity is never added across volumes.", systemImage: "square.stack.3d.up")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.top, 4)
        }
    }

    private func capacity(_ drive: StorageDrive) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(drive.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                Spacer()
                Text(drive.fileSystem).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.primary.opacity(0.04), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(diskSize(drive.free)).font(.system(size: 38, weight: .light, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text("of breathing room").font(.subheadline).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(0..<48) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Double(index) / 48 < drive.usedFraction
                                  ? (drive.usedFraction >= 0.9 ? Color.orange.opacity(0.7) : diskMint.opacity(0.7))
                                  : Color.primary.opacity(0.07))
                            .frame(width: max(1, (geometry.size.width - 141) / 48))
                    }
                }
            }.frame(height: 20).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text("\(diskSize(drive.used)) used · \(Int(drive.usedFraction * 100))%")
                Spacer()
                Text("\(diskSize(drive.total)) capacity")
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if drive.usedFraction >= 0.9 {
                Label("Space is getting tight. Review files in Files & cleanup.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(20).diskPanel()
    }

    private func activity(_ drive: StorageDrive) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Disk activity").font(.subheadline.weight(.semibold))
                Spacer()
                Picker(selection: $monitor.windowSeconds) {
                    Text("30 sec").tag(30)
                    Text("2 min").tag(120)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .accessibilityLabel("Activity history")
            }
            HStack(spacing: 32) {
                rateValue("Read", value: diskRate(monitor.latest?.readRate), color: diskMint)
                rateValue("Write", value: diskRate(monitor.latest?.writeRate), color: diskWrite)
                Spacer(minLength: 0)
                if let latest = monitor.latest {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text((latest.readIOPS + latest.writeIOPS).formatted(.number.precision(.fractionLength(0))))
                            .font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("operations / sec").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if monitor.samples.count >= 2 {
                activityChart
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path").font(.title2).foregroundStyle(.tertiary)
                    Text(monitor.totals == nil ? "Activity isn’t exposed for this volume" : "Collecting live activity…")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 112)
            }
            HStack {
                Text("Physical device · \(monitor.activityDevice ?? "unavailable")")
                Spacer()
                if let peak = monitor.samples.map({ max($0.readRate, $0.writeRate) }).max() {
                    Text("Peak \(diskRate(peak))")
                }
            }.font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
        }.padding(20).diskPanel()
    }

    private var activityChart: some View {
        let samples = monitor.samples
        let end = samples.last?.date ?? .now
        let peak = max(1, samples.map { max($0.readRate, $0.writeRate) / 1_000_000 }.max() ?? 1)
        return Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("Read MB/s", sample.readRate / 1_000_000), series: .value("Transfer", "Read"))
                    .foregroundStyle(diskMint).lineStyle(StrokeStyle(lineWidth: 1.7))
                LineMark(x: .value("Time", sample.date), y: .value("Write MB/s", sample.writeRate / 1_000_000), series: .value("Transfer", "Write"))
                    .foregroundStyle(diskWrite).lineStyle(StrokeStyle(lineWidth: 1.7, dash: [4, 2]))
            }
        }
        .chartXScale(domain: end.addingTimeInterval(-Double(monitor.windowSeconds))...end)
        .chartYScale(domain: 0...(peak * 1.15))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel { if let rate = value.as(Double.self) { Text(rate.formatted(.number.precision(.fractionLength(0...1)))) + Text(" MB/s") } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute().second()) } }
        .frame(height: 112)
        .accessibilityLabel("Read and write activity over the last \(monitor.windowSeconds) seconds")
    }

    private func health(_ drive: StorageDrive) -> some View {
        let health = drive.health
        let status = health.status ?? "Unavailable"
        let verified = status.lowercased() == "verified"
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Drive health").font(.subheadline.weight(.semibold))
                Spacer()
                Label(status, systemImage: verified ? "checkmark.shield" : "info.circle")
                    .font(.caption).foregroundStyle(verified ? diskMint : status.lowercased() == "failing" ? Color.orange : .secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                healthValue(health.lifeRemaining.map { "\($0)%" } ?? "—", label: "Life remaining", detail: "Estimated endurance")
                healthValue(health.temperature.map { "\(Int($0.rounded()))°C" } ?? "—", label: "Temperature", detail: "Device sensor")
                healthValue(health.availableSpare.map { "\($0)%" } ?? "—", label: "Available spare", detail: "Reserve capacity")
            }
            if status.lowercased() == "failing" || (health.mediaErrors ?? 0) > 0 || (health.criticalWarning ?? 0) > 0 {
                Label("The drive reports a warning. Check your backups and review diagnostics below.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    healthDetail("Lifetime read", value: health.lifetimeRead.map(diskSize) ?? "—")
                    healthDetail("Lifetime written", value: health.lifetimeWritten.map(diskSize) ?? "—")
                }
                GridRow {
                    healthDetail("Power-on hours", value: count(health.powerOnHours))
                    healthDetail("Power cycles", value: count(health.powerCycles))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("SMART readings are device-reported. A dash means the drive doesn’t expose that value.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).diskPanel()
    }

    private func deviceDetails(_ drive: StorageDrive) -> some View {
        DisclosureGroup {
            VStack(spacing: 10) {
                detailRow("Model", drive.model ?? "Unavailable")
                detailRow("Connection", drive.connection ?? "Unavailable")
                detailRow("Media", drive.isSSD.map { $0 ? "Solid-state drive" : "Hard disk" } ?? "Unavailable")
                detailRow("Volume device", drive.device ?? "Unavailable")
                detailRow("Physical device", drive.physicalDevices.isEmpty ? "Unavailable" : drive.physicalDevices.joined(separator: ", "))
                detailRow("Mount point", drive.url.path)
                detailRow("APFS container", drive.container ?? "Not applicable")
                detailRow("Encrypted", drive.encrypted.map { $0 ? "Yes" : "No" } ?? "Unavailable")
                detailRow("Writable", drive.writable.map { $0 ? "Yes" : "No" } ?? "Unavailable")
                detailRow("Removable media", drive.isRemovable ? "Yes" : "No")
                Divider()
                detailRow("Read since driver start", monitor.totals.map { diskSize(Int64(clamping: $0.read)) } ?? "Unavailable")
                detailRow("Written since driver start", monitor.totals.map { diskSize(Int64(clamping: $0.written)) } ?? "Unavailable")
                detailRow("Media errors", count(drive.health.mediaErrors))
                detailRow("Unsafe shutdowns", count(drive.health.unsafeShutdowns))
                detailRow("Critical warning", drive.health.criticalWarning.map { $0 == 0 ? "None" : "Code \($0)" } ?? "Unavailable")
                if let updated = monitor.updated {
                    detailRow("Drive details updated", updated.formatted(date: .omitted, time: .standard))
                }
            }.padding(.top, 16)
        } label: {
            Label("Device details & diagnostics", systemImage: "internaldrive")
                .font(.subheadline.weight(.medium))
        }.padding(16).diskPanel()
    }

    private func count(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0))) ?? "—"
    }
    private func rateValue(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: title == "Read" ? "arrow.down" : "arrow.up")
                .font(.caption).foregroundStyle(color)
            Text(value).font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
    private func healthValue(_ value: String, label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 26, weight: .light, design: .rounded)).monospacedDigit()
            Text(label).font(.caption)
            Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func healthDetail(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }.font(.caption).frame(maxWidth: .infinity)
    }
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.caption)
    }
}

private extension View {
    func diskPanel() -> some View {
        breezeSurface(radius: 18)
    }
}
