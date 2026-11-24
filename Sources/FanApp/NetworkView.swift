import AppKit
import Charts
import NetworkCore
import SwiftUI

private let networkMint = BreezeStyle.mint
private let networkSlate = Color(red: 0.40, green: 0.53, blue: 0.82)

private func networkBytes(_ bytes: UInt64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
}
private func networkRate(_ rate: Double?) -> String {
    guard let rate, rate.isFinite else { return "—" }
    return networkBytes(UInt64(min(Double(Int64.max / 2), max(0, rate)))) + "/s"
}
private func networkMS(_ ms: Double?) -> String {
    ms.map { "\($0.formatted(.number.precision(.fractionLength(0)))) ms" } ?? "—"
}

// Intent: a Mac owner checking a slow connection and recognizing nearby devices;
// calm, readable measurements that explain exactly what has been observed.
// Domain: packet flow, uplink, gateway, signal, neighbors, advertised services.
// Color world: aluminum surfaces, graphite text, mint link LEDs, slate cable jackets,
// amber degraded links. Mint receives and slate sends, matching Breeze's disk view.
// Signature: a Mac → gateway → internet route with a single sampled health ribbon.
// Defaults replaced: mirrored traffic → positive traces; a tile wall → time ribbon;
// dense device cards → an address-sorted inventory with evidence on inspection.
// Depth/surfaces: shared translucent content materials beneath glass controls.
// Typography: SF rounded headings and tabular data, matching the host app.
// Spacing: four-point grid, 20-point panels and 28-point outer gutters.
struct NetworkView: View {
    @Bindable var model: NetworkModel
    @State private var scrolled = false
    @State private var trafficScrub: Date?
    @Environment(\.breezeMotionLevel) private var level

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    route
                    BreezeSwitcher(model.tab, index: NetworkModel.Tab.allCases.firstIndex(of: model.tab) ?? 0) {
                        tabContent.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, BreezeStyle.pagePadding).padding(.bottom, BreezeStyle.pagePadding)
                    .breezeScrollEdge($scrolled)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "network").foregroundStyle(networkMint)
                Text(model.tab == .activity ? "Traffic every 1s · connection details every 5s" : model.tab == .apps ? "Per-app traffic since Breeze opened · every 1s" : "Discovery stays on your local network")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Toggle("Internet checks", isOn: $model.internetChecks).toggleStyle(.switch).controlSize(.mini)
                    .font(.caption2).help("TCP probes to Cloudflare every 5 seconds and a public IPv4/country lookup every minute while this page is open.")
            }.padding(.horizontal, BreezeStyle.pagePadding).frame(height: 44)
        }.task { await model.run() }
            .onDisappear { model.stopScanning(); model.stopSpeedTest() }
            .sheet(item: $model.inspected) { device in NetworkDeviceDetail(model: model, device: device) }
    }

    @ViewBuilder private var tabContent: some View {
        if model.tab == .apps {
            appInventory
        } else if model.tab == .activity {
            VStack(alignment: .leading, spacing: 20) {
                speedTest
                traffic
                health
                HStack(alignment: .top, spacing: 16) {
                    interface.frame(maxWidth: .infinity)
                    addresses.frame(maxWidth: .infinity)
                }
            }
        } else { deviceInventory }
    }

    private var header: some View {
        BreezePageHeader("Network", subtitle: "Your connection, and the devices around it.", scrolled: scrolled) {
            Picker("Network view", selection: $model.tab) {
                ForEach(NetworkModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
        }
    }

    private var route: some View {
        HStack(spacing: 16) {
            Image(systemName: model.connection.kind == "Wi-Fi" ? "wifi" : "cable.connector")
                .font(.system(size: 25, weight: .light)).foregroundStyle(networkMint).frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.connection.ssid ?? model.connection.name).font(.headline).lineLimit(1)
                Text(model.connection.interface.isEmpty ? "Waiting for a network interface" : "\(model.connection.kind) · \(model.connection.interface)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            NetworkRouteDiagram(download: model.traffic.last?.download ?? 0, upload: model.traffic.last?.upload ?? 0,
                                broken: internetBroken)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                        .breezePulse(trigger: healthState, tint: statusColor)
                        .breezeAnimation(.settle, value: healthState)
                    Text(model.status).font(.caption.weight(.medium))
                }
                Text(model.connection.gateway.map { "Gateway \($0)" } ?? "No gateway reported")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }.padding(20).networkPanel()
    }
    private var internetBroken: Bool { model.internetChecks && model.connectivity.last?.reachable == false }
    private var statusColor: Color {
        if !model.connection.isUp { return model.loading ? .secondary : .orange }
        return internetBroken ? .orange : networkMint
    }
    /// Changes only when the status colour's meaning changes, so the dot pulses once per reachability change.
    private var healthState: Int { !model.connection.isUp ? (model.loading ? 0 : 1) : internetBroken ? 1 : 2 }

    private var speedTest: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label {
                    Text("Internet speed test")
                } icon: {
                    Image(systemName: "speedometer")
                        .symbolEffect(.variableColor.iterative, isActive: model.testingSpeed && level.isActive)
                }.font(.subheadline.weight(.semibold))
                Spacer()
                ZStack(alignment: .trailing) {
                    if model.testingSpeed {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { model.stopSpeedTest() }
                        }.transition(.breezeFade)
                    } else {
                        Button(model.speedResult == nil ? "Start test" : "Test again", systemImage: "play.fill") { model.startSpeedTest() }
                            .breezeAction(prominent: true)
                            .disabled(!model.connection.isUp || !model.internetChecks)
                            .transition(.breezeFade)
                    }
                }.breezeAnimation(.settle, value: model.testingSpeed)
            }
            HStack(spacing: 32) {
                speedMeasurement("Download", symbol: "arrow.down", value: model.speedResult?.downloadMbps, color: networkMint)
                speedMeasurement("Upload", symbol: "arrow.up", value: model.speedResult?.uploadMbps, color: networkSlate)
                Spacer(minLength: 0)
                measurement("Idle latency", value: networkMS(model.speedResult?.idleLatency))
            }
            let caption = !model.internetChecks ? "Enable Internet checks to run a speed test." : !model.connection.isUp ? "Connect to the internet to start a test." : model.speedMessage
            Text(caption)
                .font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                .contentTransition(.opacity).breezeAnimation(.settle, value: caption)
            Group {
                if let error = model.speedError {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).transition(.breezeDrop)
                }
            }.breezeAnimation(.settle, value: model.speedError)
            Text("Uses Apple’s network quality test. Download and upload are measured together. Tests use significant internet data and can briefly slow other activity.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).networkPanel()
    }

    private func speedMeasurement(_ title: String, symbol: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Group {
                    if let value {
                        // New identity per completed test; the key keeps a revisit of the page from replaying it.
                        let result = model.speedResult?.date.timeIntervalSince1970 ?? 0
                        BreezeCountUp(value, key: "network.speed.\(result)") { $0.formatted(.number.precision(.fractionLength(1))) }
                            .id(model.speedResult?.date)
                    } else { Text("—") }
                }.font(.system(size: 29, weight: .light, design: .rounded)).monospacedDigit()
                Text("Mbps").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(minWidth: 150, alignment: .leading)
    }

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Traffic").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Traffic history", selection: $model.windowSeconds) {
                    Text("2 min").tag(120); Text("5 min").tag(300)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 126)
            }
            HStack(alignment: .top, spacing: 32) {
                rate("Download", symbol: "arrow.down", value: model.traffic.last?.download, total: model.counters?.received, color: networkMint)
                rate("Upload", symbol: "arrow.up", value: model.traffic.last?.upload, total: model.counters?.sent, color: networkSlate)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Interface totals").font(.caption).foregroundStyle(.secondary)
                    Text("Since interface reset").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            let samples = model.samples
            Group {
                if samples.count >= 2 { trafficChart(samples) } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path").font(.title2).foregroundStyle(.tertiary)
                        Text(model.connection.isUp ? "Collecting live traffic…" : "Connect to a network to see traffic")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).frame(height: 128).transition(.breezeFade)
                }
            }.breezeAnimation(.settle, value: samples.count >= 2)
            Text("All traffic on \(model.connection.interface.isEmpty ? "the active interface" : model.connection.interface), including local transfers. Use the internet speed test above to measure your connection’s capacity.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).networkPanel()
    }

    private func trafficChart(_ samples: [NetworkTraffic]) -> some View {
        // The domain ends at the newest sample, so hovering never slides it between samples.
        let end = samples.last?.date ?? .now
        let selected = trafficScrub.flatMap { BreezeMotion.nearest(samples, to: $0, by: \.date) }
        return Chart {
            ForEach(samples) { point in
                LineMark(x: .value("Time", point.date), y: .value("Bytes/s", point.download), series: .value("Direction", "Download"))
                    .foregroundStyle(networkMint).lineStyle(StrokeStyle(lineWidth: 1.8)).interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value("Bytes/s", point.upload), series: .value("Direction", "Upload"))
                    .foregroundStyle(networkSlate).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
            }
            if let selected {
                RuleMark(x: .value("Time", selected.date)).foregroundStyle(.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        BreezeChartCallout(title: selected.date.formatted(date: .omitted, time: .standard),
                                           value: "↓ \(networkRate(selected.download))  ↑ \(networkRate(selected.upload))")
                    }
                PointMark(x: .value("Time", selected.date), y: .value("Bytes/s", selected.download))
                    .foregroundStyle(networkMint).symbolSize(48)
                PointMark(x: .value("Time", selected.date), y: .value("Bytes/s", selected.upload))
                    .foregroundStyle(networkSlate).symbolSize(48)
            }
        }.chartYScale(domain: 0...max(1024, samples.map { max($0.download, $0.upload) }.max() ?? 1024))
            .chartXScale(domain: end.addingTimeInterval(-Double(model.windowSeconds))...end)
            .chartPlotStyle { $0.breezeChartDrawIn(key: "network.traffic") }
            .breezeAnimation(.settle, value: model.windowSeconds)
            .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.primary.opacity(0.05))
                            AxisValueLabel { if let bytes = value.as(Double.self) { Text(networkRate(bytes)).font(.system(size: 9)).foregroundStyle(.secondary) } }
                        }
                    }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute().second()) } }
                    .breezeChartScrub($trafficScrub)
                    .breezeChartKeys($trafficScrub, dates: samples.map(\.date))
                    .frame(height: 128)
                    .accessibilityLabel("Live download and upload traffic, in bytes per second")
                    .transition(.breezeFade)
    }

    private func rate(_ title: String, symbol: String, value: Double?, total: UInt64?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            Text(networkRate(value)).font(.system(size: 29, weight: .light, design: .rounded)).breezeLive().lineLimit(1).minimumScaleFactor(0.7)
            Text("\(networkBytes(total)) transferred").font(.caption2).foregroundStyle(.secondary).breezeLive()
        }.frame(minWidth: 150, alignment: .leading)
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Connection health").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.internetChecks ? "TCP · 1.1.1.1:443" : "Internet checks paused")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                measurement("Latency", value: networkMS(model.latency))
                measurement("Jitter", value: networkMS(model.jitter))
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(model.connectivity.isEmpty ? "—" : "\(Int(Double(model.connectivity.filter(\.reachable).count) / Double(model.connectivity.count) * 100))%")
                        .font(.system(size: 23, weight: .light, design: .rounded)).breezeLive()
                    Text("Successful probes").font(.caption2).foregroundStyle(.secondary)
                }
            }
            NetworkConnectivityStrip(samples: model.connectivity)
            HStack {
                Label("Reachable", systemImage: "circle.fill").foregroundStyle(networkMint)
                Label("Probe failed", systemImage: "circle.fill").foregroundStyle(.orange)
                Spacer()
                Text("Up to 10 minutes · sampled every ~5s")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Latency is a TCP handshake. Jitter is the average change between consecutive probes. A failed probe can also mean the endpoint is blocked.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).networkPanel()
    }
    private func measurement(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 23, weight: .light, design: .rounded)).breezeLive()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var interface: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Interface").font(.subheadline.weight(.semibold))
            detail("Connection", model.connection.kind)
            detail("Status", model.connection.isUp ? "Up" : "Down")
            detail("Physical address", model.connection.mac)
            detail("Standard", model.connection.standard)
            detail("Security", model.connection.security)
            detail("Channel", model.connection.channel)
            detail("Signal / noise", model.connection.signal.map { "\($0) / \(model.connection.noise.map(String.init) ?? "—") dBm" })
            detail("Link speed", model.connection.linkMbps.map { "\($0.formatted(.number.precision(.fractionLength(0)))) Mbps" })
            if model.connection.kind == "Wi-Fi", model.connection.ssid == nil {
                Button("Allow Wi-Fi name", systemImage: "location") { model.requestWiFiName() }
                    .buttonStyle(.borderless).font(.caption).help("macOS may require Location Services to expose the Wi-Fi network name.")
            }
            Text("Some Wi-Fi readings depend on hardware and macOS permissions.").font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).networkPanel()
    }
    private var addresses: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Addresses").font(.subheadline.weight(.semibold))
                Spacer()
                Button { Task { await model.refreshPublicIP() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).help("Refresh public IPv4 address")
                    .accessibilityLabel("Refresh public IPv4 address").disabled(model.checkingPublic || !model.internetChecks || !model.connection.isUp)
            }
            detail("Local IPv4", model.connection.ipv4)
            detail("Subnet mask", model.connection.netmask)
            detail("Gateway", model.connection.gateway)
            detail("Public IPv4", model.publicIP)
            detail("Country", model.country.flatMap { Locale.current.localizedString(forRegionCode: $0).map { "\($0) (\(model.country!))" } })
            detail("DNS servers", model.connection.dns.isEmpty ? nil : model.connection.dns.joined(separator: ", "))
            detail("IPv6", model.connection.ipv6.isEmpty ? nil : model.connection.ipv6.joined(separator: "\n"))
            if let error = model.publicError { Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("Public IPv4 and approximate country come from Cloudflare via HTTPS. A VPN or proxy can change the result.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            if let updated = model.publicUpdated {
                Text("Lookup \(updated.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).networkPanel()
    }
    private func detail(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value ?? "—").multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }

    private var appInventory: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Apps using the network").font(.title3.weight(.semibold))
                    Text(model.appUsageSince.map { "Totals since \($0.formatted(date: .omitted, time: .shortened)) · current rates" } ?? "Reading per-app traffic…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset totals", systemImage: "arrow.counterclockwise") { model.resetAppUsage() }
                    .disabled(model.appUsage.isEmpty)
            }
            if let error = model.appUsageError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            let rows = Array(model.sortedAppUsage.prefix(40))
            Group { if rows.isEmpty {
                VStack(spacing: 10) {
                    BreezeDelayedProgress().controlSize(.small)
                    Text("Waiting for network activity…").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 48).networkPanel().transition(.breezeFade)
            } else {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("Process"); Spacer()
                        Text("Download").frame(width: 92, alignment: .trailing)
                        Text("Upload").frame(width: 92, alignment: .trailing)
                        Text("Total").frame(width: 92, alignment: .trailing)
                    }.font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
                    ForEach(rows) { usage in appRow(usage) }
                }.networkPanel().transition(.breezeFade)
            } }.breezeAnimation(.settle, value: rows.isEmpty)
            Text("Includes local and loopback traffic. Processes are listed by name and PID; helper processes appear separately from their app. Totals count every connection since Breeze opened, including ones that have already closed, and are not saved. Traffic from before Breeze opened is not included.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// Live rate over the session total for one direction, so finished transfers stay visible.
    private func directionCell(rate: Double, total: UInt64, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(networkRate(rate)).foregroundStyle(rate > 0 ? color : .secondary).breezeLive()
            Text(networkBytes(total)).font(.caption2).foregroundStyle(.secondary).breezeLive()
        }.frame(width: 92, alignment: .trailing)
    }
    private func appRow(_ usage: AppNetworkUsage) -> some View {
        let app = NSRunningApplication(processIdentifier: usage.pid)
        return HStack(spacing: 12) {
            Group {
                if let icon = app?.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "terminal").foregroundStyle(.secondary) }
            }.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(app?.localizedName ?? usage.name).font(.subheadline).lineLimit(1)
                Text("PID \(usage.pid)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            directionCell(rate: usage.download, total: usage.received, color: networkMint)
            directionCell(rate: usage.upload, total: usage.sent, color: networkSlate)
            Text(networkBytes(usage.received + usage.sent)).breezeLive().frame(width: 92, alignment: .trailing)
        }.font(.system(size: 12)).monospacedDigit().padding(.horizontal, 16).padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider().opacity(0.4).padding(.leading, 50) }
            .accessibilityElement(children: .combine)
    }

    private var deviceInventory: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("On your network").font(.title3.weight(.semibold))
                    Text(model.scanMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.stopScanning() }
                } else {
                    Button("Scan devices", systemImage: "dot.radiowaves.left.and.right") { model.startScanning() }
                        .breezeAction(prominent: true).disabled(model.subnet == nil || !model.connection.isUp)
                }
            }
            Group {
                if model.scanning { BreezeMeter(fraction: model.scanProgress, tint: networkMint).transition(.breezeFade) }
            }.breezeAnimation(.settle, value: model.scanning)
            if let error = model.discoveryError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!) }
                        .controlSize(.small)
                }
            }
            Group { if model.subnet == nil {
                ContentUnavailableView("No supported local IPv4 network", systemImage: "network.slash",
                    description: Text("Connect to a private Wi-Fi or Ethernet network to discover devices. Public-address, IPv6-only and VPN interfaces are not swept."))
                    .transition(.breezeFade)
            } else if model.devices.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.router").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(networkMint)
                        .symbolEffect(.variableColor.iterative, isActive: model.scanning && level.isActive)
                    Text("Get to know your network").font(.title3.weight(.medium))
                    Text("Find nearby computers, phones, printers and media devices.\nBreeze checks local addresses and listens for advertised names.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("macOS will ask for Local Network access on your first scan.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity).padding(.vertical, 64).networkPanel().transition(.breezeFade)
            } else {
                HStack {
                    TextField("Search name, address or device type", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    Spacer()
                    Text("\(model.filteredDevices.count) devices").font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredDevices) { device in deviceRow(device).transition(.breezeDrop) }
                    if model.filteredDevices.isEmpty { Text("No devices match your search.").font(.subheadline).foregroundStyle(.secondary).padding(32) }
                }.networkPanel().breezeAnimation(.settle, value: model.devices.count).transition(.breezeFade)
            } }.breezeAnimation(.settle, value: model.subnet == nil ? 0 : model.devices.isEmpty ? 1 : 2)
            Text("Names and models come from device advertisements; types are inferred from services. A neighbor record alone does not confirm that a device is online. Sleeping devices and isolated Wi-Fi clients may be missed. Private MAC addresses limit identification. If an iPhone stays unidentified, unlock it and scan again; iOS may not advertise a name or model. You can also give it a name in device details.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.subnet?.isLimited == true {
                Label("Large network: the address scan covers only this Mac’s /24. Neighbor records and Bonjour can add devices from the wider subnet.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func deviceRow(_ device: LocalDevice) -> some View {
        Button { model.inspected = device } label: {
            HStack(spacing: 16) {
                Image(systemName: device.symbol).font(.system(size: 22, weight: .light)).foregroundStyle(networkMint)
                    .frame(width: 40, height: 40).background(networkMint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.displayName(device)).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text([device.category, device.model].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(device.ip).font(.system(size: 12, design: .monospaced))
                    Text(device.mac ?? "MAC unavailable").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text(device.responded ? "Responded" : "Neighbor record").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(device.responded ? networkMint : .secondary).frame(width: 90, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).breezeNudge(x: 2)
            }.padding(16).contentShape(Rectangle())
        }.buttonStyle(.breezeRow).overlay(alignment: .bottom) { Divider().opacity(0.4).padding(.leading, 72) }
            .accessibilityLabel("\(model.displayName(device)), \(device.ip), \(device.evidence). Show device details.")
    }
}

private struct NetworkDeviceDetail: View {
    @Bindable var model: NetworkModel
    let device: LocalDevice
    @State private var alias = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: device.symbol).font(.system(size: 32, weight: .light)).foregroundStyle(networkMint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName(device)).font(.title2.weight(.semibold))
                    Text(device.category).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                row("IPv4", device.ip)
                row("MAC address", device.mac ?? "Unavailable")
                row("Advertised name", device.name ?? "Unavailable")
                row("Model", device.model ?? "Not advertised")
                row("Manufacturer", device.manufacturer ?? "Not advertised")
                row("Evidence", device.evidence)
                row("Observed", device.lastSeen.formatted(date: .omitted, time: .standard))
            }.font(.subheadline).textSelection(.enabled)
            if !device.services.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Advertised services").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(device.services.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if device.hasPrivateMAC {
                Label("This is a locally administered MAC address. It may be private or randomized, so manufacturer identification is unreliable.", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            TextField("Your name for this device", text: $alias).textFieldStyle(.roundedBorder)
            Text("Optional. Saved only on this Mac. Leave blank to use the discovered name.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save name") { model.saveAlias(alias, for: device); dismiss() }.breezeAction(prominent: true).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500).breezeAction()
            .onAppear { alias = model.displayName(device) == device.name || model.displayName(device) == device.category ? "" : model.displayName(device) }
    }
    private func row(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).fixedSize(horizontal: false, vertical: true) }
    }
}

// MARK: - Route diagram

/// Integrates time from TimelineView dates; never written to observable state.
private final class PacketClock {
    private var last: Date?
    private var phase = 0.0
    func advance(to date: Date) -> Double {
        defer { last = date }
        if let last { phase += min(max(date.timeIntervalSince(last), 0), 0.25) }
        return phase
    }
}

private struct RouteLine: Shape {
    let from: CGFloat
    let to: CGFloat
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: from, y: rect.midY))
            path.addLine(to: CGPoint(x: to, y: rect.midY))
        }
    }
}

/// Mac, router and internet joined by a path; packets travel it at a rate bound to live traffic.
private struct NetworkRouteDiagram: View {
    let download: Double
    let upload: Double
    let broken: Bool
    @State private var progress: CGFloat
    @State private var clock = PacketClock()
    @Environment(\.breezeMotionLevel) private var level
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let size = CGSize(width: 176, height: 28)
    private static let first: ClosedRange<CGFloat> = 24...76
    private static let second: ClosedRange<CGFloat> = 100...152
    private static let router: CGFloat = 88
    private static let travel = 2.4
    private static let floor = 1_000.0

    init(download: Double, upload: Double, broken: Bool) {
        self.download = download
        self.upload = upload
        self.broken = broken
        _progress = State(initialValue: BreezeMotion.firstTime("network.route") ? 0 : 1)
    }

    var body: some View {
        let flowing = level.isActive && (download >= Self.floor || upload >= Self.floor)
        ZStack {
            RouteLine(from: Self.first.lowerBound, to: Self.first.upperBound)
                .trim(from: 0, to: min(progress * 2, 1))
                .stroke(networkMint.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            RouteLine(from: Self.second.lowerBound, to: Self.second.upperBound)
                .trim(from: 0, to: max(progress * 2 - 1, 0))
                .stroke(networkMint.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .opacity(broken ? 0 : 1)
            RouteLine(from: Self.second.lowerBound, to: Self.second.upperBound)
                .trim(from: 0, to: max(progress * 2 - 1, 0))
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
                .opacity(broken ? 1 : 0)
            Group {
                Image(systemName: "laptopcomputer").position(x: 10, y: Self.size.height / 2)
                Image(systemName: "wifi.router").position(x: Self.router, y: Self.size.height / 2)
                Image(systemName: "globe").position(x: 166, y: Self.size.height / 2)
            }.foregroundStyle(.tertiary).font(.system(size: 15))
            if flowing {
                TimelineView(.animation(minimumInterval: level.interval(fps: 20))) { context in
                    let phase = clock.advance(to: context.date)
                    Canvas { gc, _ in drawPackets(&gc, phase: phase) }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .breezeAnimation(.settle, value: broken)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard progress < 1 else { return }
            if reduceMotion { progress = 1 } else { withAnimation(BreezeMotion.draw) { progress = 1 } }
        }
    }

    /// Stateless: each packet's position is a function of the integrated phase, the emit interval and its index.
    private func drawPackets(_ gc: inout GraphicsContext, phase: Double) {
        let start = Self.first.lowerBound
        let end = broken ? Self.router : Self.second.upperBound
        for (rate, color, towardMac, dy) in [(download, networkMint, true, CGFloat(-2.5)), (upload, networkSlate, false, CGFloat(2.5))] {
            guard rate >= Self.floor else { continue }
            let interval = min(max(1.2 - log10(max(rate, 1)) * 0.18, 0.15), 1.2)
            let count = min(12, max(1, Int((Self.travel / interval).rounded())))
            for index in 0..<count {
                let along = (phase / Self.travel + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)
                let x = start + (end - start) * CGFloat(towardMac ? 1 - along : along)
                // Packets pass behind the router and stop there when the internet is unreachable.
                guard Self.first.contains(x) || (!broken && Self.second.contains(x)) else { continue }
                gc.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: Self.size.height / 2 + dy - 1.5, width: 3, height: 3)), with: .color(color))
            }
        }
    }
}

// MARK: - Connectivity strip

private struct NetworkProbeBar: View {
    let sample: ConnectivitySample
    let lifted: Bool
    @State private var grown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(sample: ConnectivitySample, grows: Bool, lifted: Bool) {
        self.sample = sample
        self.lifted = lifted
        _grown = State(initialValue: !grows)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(sample.reachable ? networkMint.opacity(0.8) : Color.orange.opacity(0.8))
            .frame(height: 16)
            .scaleEffect(y: grown || reduceMotion ? 1 : 0.001, anchor: .bottom)
            .offset(y: lifted ? -2 : 0)
            .breezeAnimation(.hover, value: lifted)
            .help("\(sample.date.formatted(date: .omitted, time: .standard)) · \(sample.reachable ? networkMS(sample.milliseconds) : "Probe failed")")
            .onAppear { if !grown { BreezeMotion.animate(.settle) { grown = true } } }
    }
}

/// Probe history: only probes newer than the strip's appearance grow in. One focus stop; hover or
/// left/right arrows pick a probe and show its time and latency.
private struct NetworkConnectivityStrip: View {
    let samples: [ConnectivitySample]
    @State private var appeared = Date.now
    @State private var selected: Date?

    private static let slots = 120
    private static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let barWidth = max(1, (geometry.size.width - Self.gap * CGFloat(Self.slots - 1)) / CGFloat(Self.slots))
            let pitch = barWidth + Self.gap
            HStack(alignment: .bottom, spacing: Self.gap) {
                ForEach(samples, id: \.date) { sample in
                    NetworkProbeBar(sample: sample, grows: sample.date > appeared, lifted: selected == sample.date)
                        .frame(width: barWidth)
                }
                ForEach(samples.count..<max(samples.count, Self.slots), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)).frame(width: barWidth, height: 16)
                        .help("No sample yet")
                }
            }.frame(height: 18, alignment: .bottom).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let index = Int(point.x / pitch)
                        selected = samples.indices.contains(index) ? samples[index].date : nil
                    case .ended: selected = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let probe = samples.first(where: { $0.date == selected }), let index = samples.firstIndex(where: { $0.date == selected }) {
                        // Half of a callout's typical width keeps it inside the strip.
                        let centre = min(max(CGFloat(index) * pitch + barWidth / 2, 60), max(geometry.size.width - 60, 60))
                        BreezeChartCallout(title: probe.date.formatted(date: .omitted, time: .standard),
                                           value: probe.reachable ? networkMS(probe.milliseconds) : "Probe failed",
                                           tint: probe.reachable ? networkMint : .orange)
                            .position(x: centre, y: -24).allowsHitTesting(false)
                    }
                }
        }.frame(height: 18)
            .focusable(interactions: .activate)
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .onKeyPress(.escape) {
                guard selected != nil else { return .ignored }
                selected = nil
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connectivity history, \(samples.count) probes collected")
            .accessibilityValue(samples.first { $0.date == selected }.map {
                "\($0.date.formatted(date: .omitted, time: .standard)), \($0.reachable ? networkMS($0.milliseconds) : "Probe failed")"
            } ?? "")
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard !samples.isEmpty else { return .ignored }
        let current = samples.firstIndex { $0.date == selected } ?? (delta > 0 ? -1 : samples.count)
        selected = samples[min(max(current + delta, 0), samples.count - 1)].date
        return .handled
    }
}

private extension View {
    func networkPanel() -> some View {
        breezeSurface(radius: 18)
    }
}
