import AppKit
import Charts
import NetworkCore
import SwiftUI

private let networkMint = Color(red: 0.22, green: 0.67, blue: 0.55)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    route
                    if model.tab == .activity {
                        speedTest
                        traffic
                        health
                        HStack(alignment: .top, spacing: 16) {
                            interface.frame(maxWidth: .infinity)
                            addresses.frame(maxWidth: .infinity)
                        }
                    } else { deviceInventory }
                }.padding(.horizontal, 28).padding(.bottom, 28)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "network").foregroundStyle(networkMint)
                Text(model.tab == .activity ? "Traffic every 1s · connection details every 5s" : "Discovery stays on your local network")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Toggle("Internet checks", isOn: $model.internetChecks).toggleStyle(.switch).controlSize(.mini)
                    .font(.caption2).help("TCP probes to Cloudflare every 5 seconds and a public IPv4/country lookup every minute while this page is open.")
            }.padding(.horizontal, 28).frame(height: 44)
        }.task { await model.run() }
            .onDisappear { model.stopScanning(); model.stopSpeedTest() }
            .sheet(item: $model.inspected) { device in NetworkDeviceDetail(model: model, device: device) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Network").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Your connection, and the devices around it.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Network view", selection: $model.tab) {
                ForEach(NetworkModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
        }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 24)
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
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                Image(systemName: "chevron.right").font(.system(size: 8))
                Image(systemName: "wifi.router")
                Image(systemName: "chevron.right").font(.system(size: 8))
                Image(systemName: "globe")
            }.foregroundStyle(.tertiary).font(.system(size: 15)).accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(model.status).font(.caption.weight(.medium))
                }
                Text(model.connection.gateway.map { "Gateway \($0)" } ?? "No gateway reported")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }.padding(20).networkPanel()
    }
    private var statusColor: Color {
        if !model.connection.isUp { return model.loading ? .secondary : .orange }
        return model.internetChecks && model.connectivity.last?.reachable == false ? .orange : networkMint
    }

    private var speedTest: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Internet speed test", systemImage: "speedometer").font(.subheadline.weight(.semibold))
                Spacer()
                if model.testingSpeed {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.stopSpeedTest() }
                } else {
                    Button(model.speedResult == nil ? "Start test" : "Test again", systemImage: "play.fill") { model.startSpeedTest() }
                        .breezeAction(prominent: true)
                        .disabled(!model.connection.isUp || !model.internetChecks)
                }
            }
            HStack(spacing: 32) {
                speedMeasurement("Download", symbol: "arrow.down", value: model.speedResult?.downloadMbps, color: networkMint)
                speedMeasurement("Upload", symbol: "arrow.up", value: model.speedResult?.uploadMbps, color: networkSlate)
                Spacer(minLength: 0)
                measurement("Idle latency", value: networkMS(model.speedResult?.idleLatency))
            }
            Text(!model.internetChecks ? "Enable Internet checks to run a speed test." : !model.connection.isUp ? "Connect to the internet to start a test." : model.speedMessage)
                .font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
            if let error = model.speedError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Uses Apple’s network quality test. Download and upload are measured together. Tests use significant internet data and can briefly slow other activity.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).networkPanel()
    }

    private func speedMeasurement(_ title: String, symbol: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                    .font(.system(size: 29, weight: .light, design: .rounded)).monospacedDigit()
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
            if model.samples.count >= 2 {
                Chart(model.samples) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Bytes/s", point.download), series: .value("Direction", "Download"))
                        .foregroundStyle(networkMint).lineStyle(StrokeStyle(lineWidth: 1.8))
                    LineMark(x: .value("Time", point.date), y: .value("Bytes/s", point.upload), series: .value("Direction", "Upload"))
                        .foregroundStyle(networkSlate).lineStyle(StrokeStyle(lineWidth: 1.5))
                }.chartYScale(domain: 0...max(1024, model.samples.map { max($0.download, $0.upload) }.max() ?? 1024))
                    .chartXScale(domain: Date.now.addingTimeInterval(-Double(model.windowSeconds))...Date.now)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.primary.opacity(0.05))
                            AxisValueLabel { if let bytes = value.as(Double.self) { Text(networkRate(bytes)).font(.system(size: 9)).foregroundStyle(.secondary) } }
                        }
                    }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute().second()) } }
                    .frame(height: 128)
                    .accessibilityLabel("Live download and upload traffic, in bytes per second")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path").font(.title2).foregroundStyle(.tertiary)
                    Text(model.connection.isUp ? "Collecting live traffic…" : "Connect to a network to see traffic")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 128)
            }
            Text("All traffic on \(model.connection.interface.isEmpty ? "the active interface" : model.connection.interface), including local transfers. Use the internet speed test above to measure your connection’s capacity.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).networkPanel()
    }

    private func rate(_ title: String, symbol: String, value: Double?, total: UInt64?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            Text(networkRate(value)).font(.system(size: 29, weight: .light, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text("\(networkBytes(total)) transferred").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
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
                        .font(.system(size: 23, weight: .light, design: .rounded)).monospacedDigit()
                    Text("Successful probes").font(.caption2).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(0..<120, id: \.self) { index in
                        let sample = index < model.connectivity.count ? model.connectivity[index] : nil
                        RoundedRectangle(cornerRadius: 2).fill(sample.map { $0.reachable ? networkMint.opacity(0.8) : Color.orange.opacity(0.8) } ?? Color.primary.opacity(0.06))
                            .frame(width: max(1, (geometry.size.width - 238) / 120))
                            .help(sample.map { "\($0.date.formatted(date: .omitted, time: .standard)) · \($0.reachable ? networkMS($0.milliseconds) : "Probe failed")" } ?? "No sample yet")
                    }
                }
            }.frame(height: 18).accessibilityElement(children: .ignore)
                .accessibilityLabel("Connectivity history, \(model.connectivity.count) probes collected")
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
            Text(value).font(.system(size: 23, weight: .light, design: .rounded)).monospacedDigit()
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
            if model.scanning { ProgressView(value: model.scanProgress).tint(networkMint) }
            if let error = model.discoveryError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!) }
                        .controlSize(.small)
                }
            }
            if model.subnet == nil {
                ContentUnavailableView("No supported local IPv4 network", systemImage: "network.slash",
                    description: Text("Connect to a private Wi-Fi or Ethernet network to discover devices. Public-address, IPv6-only and VPN interfaces are not swept."))
            } else if model.devices.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.router").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(networkMint)
                    Text("Get to know your network").font(.title3.weight(.medium))
                    Text("Find nearby computers, phones, printers and media devices.\nBreeze checks local addresses and listens for advertised names.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("macOS will ask for Local Network access on your first scan.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity).padding(.vertical, 64).networkPanel()
            } else {
                HStack {
                    TextField("Search name, address or device type", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    Spacer()
                    Text("\(model.filteredDevices.count) devices").font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredDevices) { device in deviceRow(device) }
                    if model.filteredDevices.isEmpty { Text("No devices match your search.").font(.subheadline).foregroundStyle(.secondary).padding(32) }
                }.networkPanel()
            }
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
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(16).contentShape(Rectangle())
        }.buttonStyle(.plain).overlay(alignment: .bottom) { Divider().opacity(0.4).padding(.leading, 72) }
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

private extension View {
    func networkPanel() -> some View {
        breezeSurface(radius: 18)
    }
}
