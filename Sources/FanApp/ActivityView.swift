import AppKit
import Charts
import FanCore
import SwiftUI

// Native system typography, tabular data, 8-point spacing, quiet layered surfaces.
// Green identifies live activity; semantic colors identify CPU and memory components.
struct ActivityView<Thermal: View>: View {
    @Bindable var model: ActivityModel
    let thermal: Thermal
    private let accent = Color(red: 0.22, green: 0.67, blue: 0.55)
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Statistics").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("A closer look at what’s keeping your Mac busy.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.paused.toggle() } label: {
                    Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
                }.help(model.paused ? "Resume live readings" : "Pause live readings")
            }
            HStack(spacing: 16) {
                Picker("Resource", selection: $model.tab) {
                    ForEach(ActivityModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 480)
                Spacer(minLength: 0)
                if model.tab != .processes && model.tab != .thermal {
                    Picker("History", selection: $model.windowSeconds) {
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                    }.frame(width: 145)
                }
            }
            if model.tab == .processes {
                ActivityProcessesView(model: model)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch model.tab {
                        case .cpu: cpu
                        case .gpu: gpu
                        case .memory: memory
                        case .thermal: thermal
                        case .processes: EmptyView()
                        }
                    }.padding(.bottom, 4)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(model.paused ? Color.orange : accent).frame(width: 6, height: 6)
                Text(model.paused ? "Paused" : "Updates every 2 seconds")
                if let date = model.latest?.date {
                    Text("·"); Text(date, style: .time).monospacedDigit()
                }
                Spacer()
                Text("History stays on this Mac for this session.")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 26).padding(.top, 30).padding(.bottom, 18)
        .task { await model.run() }
    }

    private var cpu: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                ActivityRing(value: model.latest?.cpu?.used, color: accent)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(model.cpuName).font(.headline)
                        Spacer()
                        Text("\(model.logicalCores) logical cores").font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.blue).frame(width: proxy.size.width * (model.latest?.cpu?.user ?? 0) / 100)
                            Rectangle().fill(Color.orange).frame(width: proxy.size.width * (model.latest?.cpu?.system ?? 0) / 100)
                            Spacer(minLength: 0)
                        }.background(.primary.opacity(0.08)).clipShape(Capsule())
                    }.frame(height: 9)
                    HStack(spacing: 20) {
                        legend("User", value: percent(model.latest?.cpu?.user), color: .blue)
                        legend("System", value: percent(model.latest?.cpu?.system), color: .orange)
                        legend("Idle", value: percent(model.latest?.cpu?.idle), color: .gray)
                    }
                }
            }.padding(20).activitySurface()
            historyChart("CPU utilization", value: { $0.cpu?.used })
            powerPanel
            if model.latest?.power?.cpuWatts != nil {
                historyChart("CPU power", color: .orange, unit: "W", maximum: nil, value: { $0.power?.cpuWatts })
            } else if model.latest?.power?.systemWatts != nil {
                historyChart("Whole-Mac power", color: .orange, unit: "W", maximum: nil, value: { $0.power?.systemWatts })
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Load per core").font(.headline)
                if let cores = model.latest?.cores, !cores.isEmpty {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(cores.indices, id: \.self) { i in
                            utilization("Core \(i + 1)", value: cores[i]?.used, color: accent)
                        }
                    }
                } else { Text("Reading core activity…").foregroundStyle(.secondary) }
            }.padding(20).activitySurface()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Average load").font(.headline)
                    ForEach(Array(["1 minute", "5 minutes", "15 minutes"].enumerated()), id: \.offset) { index, label in
                        valueRow(label, value: loadValue(index))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).activitySurface()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Processor").font(.headline)
                    valueRow("Physical cores", value: model.physicalCores.map(String.init) ?? "—")
                    valueRow("Logical cores", value: String(model.logicalCores))
                    Text("Load is the number of runnable or waiting tasks.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).activitySurface()
            }
        }
    }

    private var powerPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Power & frequency").font(.headline)
                Spacer()
                if let system = model.latest?.power?.systemWatts {
                    Text("Whole Mac \(watts(system))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let power = model.latest?.power {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    valueRow("CPU power", value: power.cpuWatts.map(watts) ?? "Needs helper")
                    valueRow("GPU power", value: watts(power.gpuWatts))
                    valueRow("Neural Engine power", value: power.aneWatts.map(watts) ?? "Needs helper")
                    valueRow("Whole Mac", value: power.systemWatts.map(watts) ?? "—")
                    valueRow("Efficiency cores", value: cluster(power.efficiencyMHz, power.efficiencyActive))
                    valueRow("Performance cores", value: cluster(power.performanceMHz, power.performanceActive))
                }
                if power.cpuWatts == nil {
                    HStack(alignment: .top, spacing: 10) {
                        Label("macOS shares CPU and Neural Engine energy only with privileged processes. Breeze reads them through its cooling helper while it’s connected.", systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let connect = model.connectHelper {
                            Button("Connect helper") { connect() }.breezeAction(size: .small)
                        }
                    }
                }
                Text("GPU energy and frequency residency come from the chip’s IOReport counters, the same source as powermetrics; whole-Mac power comes from the SMC. Frequency is the average while active.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.latest == nil ? "Reading power counters…" : "Power and frequency counters are unavailable on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).activitySurface()
    }
    private func watts(_ value: Double) -> String { String(format: value < 10 ? "%.2f W" : "%.1f W", max(0, value)) }
    private func mhz(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) MHz" } ?? "—" }
    private func cluster(_ frequency: Double?, _ active: Double?) -> String {
        [frequency.map { "\(Int($0.rounded())) MHz" }, active.map { "\(Int(($0 * 100).rounded()))% active" }]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—"
    }

    private var gpu: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.latest == nil {
                ProgressView("Reading graphics activity…").frame(maxWidth: .infinity, minHeight: 260)
            } else if let gpus = model.latest?.gpus, !gpus.isEmpty {
                ForEach(gpus) { gpu in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(gpu.name).font(.headline)
                            Spacer()
                            if let cores = gpu.cores { Text("\(cores) cores").font(.caption).foregroundStyle(.secondary) }
                        }
                        utilization("GPU utilization", value: gpu.utilization, color: accent)
                        if let power = model.latest?.power {
                            HStack(spacing: 20) {
                                valueRow("GPU power", value: watts(power.gpuWatts))
                                valueRow("GPU frequency", value: mhz(power.gpuMHz))
                            }
                        }
                        HStack(spacing: 20) {
                            utilization("Renderer", value: gpu.renderer, color: .blue)
                            utilization("Tiler", value: gpu.tiler, color: .purple)
                        }
                    }.padding(20).activitySurface()
                    historyChart("GPU utilization", value: { $0.gpus.first { $0.id == gpu.id }?.utilization })
                    HStack(spacing: 16) {
                        historyChart("Renderer utilization", color: .blue, value: { $0.gpus.first { $0.id == gpu.id }?.renderer })
                        historyChart("Tiler utilization", color: .purple, value: { $0.gpus.first { $0.id == gpu.id }?.tiler })
                    }
                }
            } else {
                ContentUnavailableView("GPU readings unavailable", systemImage: "square.3.layers.3d",
                    description: Text("This Mac’s graphics driver is not exposing utilization counters."))
                    .frame(minHeight: 260).frame(maxWidth: .infinity).activitySurface()
            }
            if model.latest?.power != nil {
                historyChart("GPU power", color: .purple, unit: "W", maximum: nil, value: { $0.power?.gpuWatts })
            }
            Label("System-wide FPS is not available from this monitor. Neural Engine activity appears as power on the CPU tab. GPU counters depend on your Mac’s graphics driver.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let memory = model.latest?.memory {
                HStack(spacing: 24) {
                    ActivityRing(value: memory.percent, color: .blue)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Used: \(bytes(memory.used))").font(.headline)
                            Spacer()
                            Text("Total: \(bytes(memory.total))").font(.caption).foregroundStyle(.secondary)
                        }
                        GeometryReader { proxy in
                            HStack(spacing: 0) {
                                Rectangle().fill(.blue).frame(width: proxy.size.width * fraction(memory.app, memory.total))
                                Rectangle().fill(.orange).frame(width: proxy.size.width * fraction(memory.wired, memory.total))
                                Rectangle().fill(.pink).frame(width: proxy.size.width * fraction(memory.compressed, memory.total))
                                Spacer(minLength: 0)
                            }.background(.primary.opacity(0.08)).clipShape(Capsule())
                        }.frame(height: 10)
                        HStack(spacing: 20) {
                            legend("App", value: bytes(memory.app), color: .blue)
                            legend("Wired", value: bytes(memory.wired), color: .orange)
                        }
                        HStack(spacing: 20) {
                            legend("Compressed", value: bytes(memory.compressed), color: .pink)
                            legend("Available", value: bytes(memory.available), color: .gray)
                        }
                    }
                }.padding(20).activitySurface()
            } else {
                Text("Waiting for memory readings…").foregroundStyle(.secondary).padding(20).activitySurface()
            }
            historyChart("Memory utilization", color: .blue, value: { $0.memory?.percent })
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Memory pressure").font(.headline)
                    HStack(spacing: 10) {
                        Circle().fill(pressureColor).frame(width: 10, height: 10)
                        Text(pressureName).font(.system(size: 24, weight: .medium, design: .rounded))
                    }
                    valueRow("Cached files", value: model.latest?.memory.map { bytes($0.cached) } ?? "—")
                    Text("Available memory includes reclaimable caches.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).activitySurface()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Swap").font(.headline)
                    Text(model.latest?.memory?.swapUsed.map { bytes($0) } ?? "—")
                        .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    valueRow("Allocated", value: model.latest?.memory?.swapTotal.map { bytes($0) } ?? "—")
                    Text("Disk space used to move memory out of RAM.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).activitySurface()
            }
            historyChart("Swap history", color: .blue, unit: "GB", maximum: nil, value: { $0.memory?.swapUsed.map { Double($0) / 1_073_741_824 } })
        }
    }

    private func loadValue(_ index: Int) -> String {
        guard let load = model.latest?.load, load.indices.contains(index) else { return "—" }
        return String(format: "%.2f", load[index])
    }
    private var pressureName: String {
        switch model.latest?.memory?.pressure { case 1: "Normal"; case 2: "Warning"; case 4: "Critical"; default: "Unavailable" }
    }
    private var pressureColor: Color {
        switch model.latest?.memory?.pressure { case 1: accent; case 2: .orange; case 4: .red; default: .gray }
    }
    private func fraction(_ value: UInt64, _ total: UInt64) -> Double { total > 0 ? min(1, Double(value) / Double(total)) : 0 }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
    private func legend(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).monospacedDigit()
        }.font(.caption)
    }
    private func valueRow(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.caption)
    }
    private func utilization(_ title: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(percent(value)).monospacedDigit() }.font(.caption)
            GeometryReader { proxy in
                Capsule().fill(.primary.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, (value ?? 0) / 100)))
                    }
            }.frame(height: 7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title).accessibilityValue(value == nil ? "Unavailable" : percent(value))
        }.frame(maxWidth: .infinity)
    }

    private func historyChart(_ title: String, color: Color? = nil, unit: String = "%", maximum: Double? = 100,
                              value: @escaping (ActivityReading) -> Double?) -> some View {
        let tint = color ?? accent
        let end = model.latest?.date ?? Date()
        var points: [ActivityChartPoint] = []
        var segment = 0
        var previousDate: Date?
        for sample in model.samples {
            if let number = value(sample) {
                if let previousDate, sample.date.timeIntervalSince(previousDate) > 5 { segment += 1 }
                points.append(ActivityChartPoint(date: sample.date, value: number, segment: segment))
                previousDate = sample.date
            } else { segment += 1 }
        }
        let top = maximum ?? max(1, (points.map(\.value).max() ?? 0) * 1.2)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let last = points.last { Text(String(format: unit == "%" ? "%.0f%%" : "%.2f \(unit)", last.value)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            }
            Chart(points) { point in
                AreaMark(x: .value("Time", point.date), y: .value(title, point.value), series: .value("Interval", point.segment))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value(title, point.value), series: .value("Interval", point.segment)).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.4))
            }
            .chartXScale(domain: end.addingTimeInterval(-Double(model.windowSeconds))...end)
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { mark in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisValueLabel { if let number = mark.as(Double.self) { Text(String(format: unit == "%" ? "%.0f%%" : "%.1f \(unit)", number)).font(.system(size: 9)) } }
                }
            }
            .chartXAxis { AxisMarks(values: [0.85, 0.5, 0.15].map { end.addingTimeInterval(-Double(model.windowSeconds) * $0) }) { _ in AxisValueLabel(format: .dateTime.hour().minute().second()).font(.system(size: 9)) } }
            .frame(height: 140)
            .overlay { if points.isEmpty { Text(model.latest == nil ? "Waiting for readings…" : "Waiting for an available sample…").font(.caption).foregroundStyle(.secondary) } }
            .accessibilityLabel(title)
            .accessibilityValue(points.last.map { "\($0.value.formatted()) \(unit)" } ?? "No samples")
        }.padding(20).activitySurface()
    }
}

private struct ActivityChartPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double
    let segment: Int
}

private struct ActivityRing: View {
    let value: Double?
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: 6)
            Circle().trim(from: 0, to: min(1, max(0, (value ?? 0) / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(value.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(width: 74, height: 74).accessibilityElement(children: .ignore)
            .accessibilityLabel("Utilization").accessibilityValue(value.map { "\(Int($0)) percent" } ?? "Unavailable")
    }
}

extension View {
    fileprivate func activitySurface() -> some View {
        breezeSurface(radius: 18)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
