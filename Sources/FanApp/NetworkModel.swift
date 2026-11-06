import Foundation
import CoreLocation
import Network
import NetworkCore
import Observation

struct ConnectivitySample: Identifiable {
    let id = UUID()
    let date: Date
    let milliseconds: Double?
    var reachable: Bool { milliseconds != nil }
}

@MainActor @Observable
final class NetworkModel {
    var connection = NetworkConnection()
    var loading = true
    var counters: NetworkCounters?
    var traffic: [NetworkTraffic] = []
    var connectivity: [ConnectivitySample] = []
    var publicIP: String?
    var country: String?
    var publicUpdated: Date?
    var publicError: String?
    var tab = Tab.activity
    var windowSeconds = 120
    var devices: [LocalDevice] = []
    var scanning = false
    var scanProgress = 0.0
    var scanMessage = "Discover devices sharing your local network."
    var discoveryError: String?
    var lastScan: Date?
    var inspected: LocalDevice?
    var search = ""
    var testingSpeed = false
    var speedResult: InternetSpeedResult?
    var speedError: String?
    var speedMessage = "Measure your internet download and upload speed."
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var speedGeneration = UUID()
    var checkingPublic = false
    var internetChecks = UserDefaults.standard.object(forKey: "networkInternetChecks") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(internetChecks, forKey: "networkInternetChecks")
            if !internetChecks { stopSpeedTest(); connectivity = []; publicIP = nil; country = nil; publicUpdated = nil; publicError = nil }
        }
    }
    var aliases = UserDefaults.standard.dictionary(forKey: "networkDeviceAliases") as? [String: String] ?? [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var resolvers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var scanGeneration = UUID()
    @ObservationIgnored private var publicGeneration = UUID()
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
    enum Tab: String, CaseIterable { case activity = "Activity", devices = "Devices" }
    static let serviceTypes = ["_workstation._tcp", "_smb._tcp", "_ssh._tcp", "_airplay._tcp", "_raop._tcp",
                               "_googlecast._tcp", "_ipp._tcp", "_ipps._tcp", "_http._tcp", "_hap._tcp",
                               "_companion-link._tcp", "_apple-mobdev2._tcp", "_rdlink._tcp", "_device-info._tcp"]

    var subnet: LocalSubnet? {
        guard let ip = connection.ipv4, let mask = connection.netmask else { return nil }
        return LocalSubnet(address: ip, netmask: mask)
    }
    var samples: [NetworkTraffic] {
        let now = Date.now
        return traffic.filter { $0.date.timeIntervalSince(now) >= -Double(windowSeconds) }
    }
    func requestWiFiName() { locationManager.requestWhenInUseAuthorization() }
    var latency: Double? { connectivity.last?.milliseconds }
    var jitter: Double? { NetworkMetrics.jitter(connectivity.suffix(12).map(\.milliseconds)) }
    var status: String {
        if loading { return "Reading connection" }
        if !connection.isUp { return "Disconnected" }
        if !internetChecks { return "Link connected" }
        guard let latest = connectivity.last else { return "Checking internet" }
        return latest.reachable ? "Internet reachable" : "Internet probe failed"
    }
    var filteredDevices: [LocalDevice] {
        devices.filter { device in
            search.isEmpty || [displayName(device), device.ip, device.mac ?? "", device.category,
                               device.model ?? "", device.manufacturer ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search)
        }.sorted {
            if $0.isThisMac != $1.isThisMac { return $0.isThisMac }
            if $0.isGateway != $1.isGateway { return $0.isGateway }
            return (LocalSubnet.number($0.ip) ?? 0) < (LocalSubnet.number($1.ip) ?? 0)
        }
    }
    private func aliasKey(_ device: LocalDevice) -> String {
        device.mac.map { "mac:\($0)" } ?? "\(connection.identity)|\(device.ip)"
    }
    func displayName(_ device: LocalDevice) -> String { aliases[aliasKey(device)] ?? device.name ?? device.category }
    func saveAlias(_ name: String, for device: LocalDevice) {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        aliases[aliasKey(device)] = value.isEmpty ? nil : value
        UserDefaults.standard.set(aliases, forKey: "networkDeviceAliases")
    }

    func run() async {
        async let monitoring: Void = monitorTraffic()
        async let probing: Void = monitorInternet()
        _ = await (monitoring, probing)
    }

    private func monitorTraffic() async {
        var previous: NetworkCounters?
        var lastTime: TimeInterval?
        var nextMetadata = Date.distantPast
        while !Task.isCancelled {
            if nextMetadata.timeIntervalSinceNow <= 0 {
                let current = await NetworkReader.connection()
                guard !Task.isCancelled else { return }
                if connection.identity != current.identity {
                    previous = nil; lastTime = nil; counters = nil; traffic = []; connectivity = []
                    publicIP = nil; country = nil; publicUpdated = nil; publicError = nil
                    publicGeneration = UUID()
                    stopScanning(); devices = []; lastScan = nil
                    stopSpeedTest(); speedResult = nil; speedError = nil
                }
                connection = current; loading = false
                nextMetadata = Date.now.addingTimeInterval(5)
            }
            let current = connection.isUp ? await NetworkReader.counters(interface: connection.interface) : nil
            guard !Task.isCancelled else { return }
            let time = ProcessInfo.processInfo.systemUptime
            if let previous, let current, let lastTime, time - lastTime < 10,
               let sample = NetworkTraffic.sample(previous: previous, current: current, elapsed: time - lastTime) {
                traffic.append(sample)
            }
            let cutoff = Date.now.addingTimeInterval(-300)
            traffic = Array(traffic.filter { $0.date.timeIntervalSince(cutoff) >= 0 }.suffix(300))
            counters = current; previous = current; lastTime = time
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func monitorInternet() async {
        while !Task.isCancelled {
            if !loading, internetChecks {
                let identity = connection.identity
                let result = connection.isUp ? await NetworkProbe.tcp(host: "1.1.1.1") : nil
                guard !Task.isCancelled else { return }
                if internetChecks, identity == connection.identity {
                    connectivity.append(.init(date: .now, milliseconds: result?.milliseconds))
                    let cutoff = Date.now.addingTimeInterval(-600)
                    connectivity = Array(connectivity.filter { $0.date.timeIntervalSince(cutoff) >= 0 }.suffix(120))
                    if connection.isUp, publicUpdated == nil || Date.now.timeIntervalSince(publicUpdated!) > 60 { await refreshPublicIP() }
                }
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func refreshPublicIP() async {
        guard internetChecks, !checkingPublic, connection.isUp else { return }
        checkingPublic = true
        let generation = publicGeneration
        defer { checkingPublic = false }
        do {
            let (data, response) = try await session.data(from: URL(string: "https://1.1.1.1/cdn-cgi/trace")!)
            guard !Task.isCancelled, generation == publicGeneration, internetChecks else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 16_384 else { throw URLError(.badServerResponse) }
            let pairs = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (String, String)? in
                let pair = line.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }
            let values = Dictionary(pairs, uniquingKeysWith: { _, last in last })
            guard let ip = values["ip"], LocalSubnet.number(ip) != nil else { throw URLError(.cannotParseResponse) }
            publicIP = ip
            country = values["loc"].flatMap { $0.count == 2 ? $0 : nil }
            publicUpdated = .now; publicError = nil
        } catch {
            guard !Task.isCancelled, generation == publicGeneration, internetChecks else { return }
            publicError = "Public IP lookup unavailable. \(error.localizedDescription)"
            publicUpdated = .now
        }
    }

    func startSpeedTest() {
        guard !testingSpeed, connection.isUp, internetChecks else { return }
        testingSpeed = true; speedError = nil; speedResult = nil
        speedMessage = "Measuring download and upload… This usually takes about 30 seconds."
        let generation = UUID(), interface = connection.interface
        speedGeneration = generation
        speedTask = Task {
            do {
                let result = try await InternetSpeedTest.run(interface: interface)
                guard !Task.isCancelled, speedGeneration == generation else { return }
                speedResult = result
                speedMessage = "Test completed · \(result.date.formatted(date: .omitted, time: .shortened))"
            } catch {
                guard !Task.isCancelled, speedGeneration == generation else { return }
                speedError = error.localizedDescription
                speedMessage = "Test could not finish."
            }
            guard speedGeneration == generation else { return }
            testingSpeed = false; speedTask = nil
        }
    }

    func stopSpeedTest() {
        speedGeneration = UUID()
        speedTask?.cancel(); speedTask = nil
        if testingSpeed { speedMessage = "Test cancelled." }
        testingSpeed = false
    }

    func startScanning() {
        guard !scanning, let subnet, connection.isUp else { return }
        stopScanning()
        scanning = true; scanProgress = 0; devices = []; discoveryError = nil
        scanMessage = "Looking for devices on \(subnet.cidr)…"
        let generation = scanGeneration, connection = connection
        if let ip = connection.ipv4 {
            var own = LocalDevice(ip: ip, mac: connection.mac, name: Host.current().localizedName ?? "This Mac", evidence: "Local interface")
            own.isThisMac = true; own.responded = true
            accept(own)
        }
        startBonjour(generation: generation)
        scanTask = Task {
            let initial = await LocalDiscovery.neighbors(interface: connection.interface, subnet: subnet)
            guard !Task.isCancelled, generation == scanGeneration else { return }
            initial.forEach(accept)
            async let sweep: Void = LocalDiscovery.sweep(subnet: subnet, interface: connection.interface) { [weak self] completed, total, device in
                await self?.scanUpdate(completed: completed, total: total, device: device, generation: generation)
            }
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            await sweep
            let neighbors = await LocalDiscovery.neighbors(interface: connection.interface, subnet: subnet)
            guard !Task.isCancelled, generation == scanGeneration else { return }
            neighbors.forEach(accept)
            await resolveNeighborNames(neighbors, interface: connection.interface, generation: generation)
            guard !Task.isCancelled, generation == scanGeneration else { return }
            // Let in-flight DNS resolutions finish before stopping the browsers.
            for resolver in Array(resolvers.values) { await resolver.value }
            guard !Task.isCancelled, generation == scanGeneration else { return }
            finishBonjour()
            scanning = false; scanProgress = 1; lastScan = .now
            scanMessage = "\(devices.count) devices observed · \(subnet.isLimited ? "scanned this Mac’s /24 within " : "")\(subnet.cidr)"
            scanTask = nil
        }
    }
    private func scanUpdate(completed: Int, total: Int, device: LocalDevice?, generation: UUID) {
        guard generation == scanGeneration, scanning else { return }
        scanProgress = total > 0 ? Double(completed) / Double(total) : 1
        scanMessage = completed == total ? "Listening for advertised names and services…" : "Checked \(completed) of \(total) addresses · \(devices.count) devices observed"
        if let device { accept(device) }
    }
    func stopScanning() {
        scanGeneration = UUID()
        scanTask?.cancel(); scanTask = nil
        finishBonjour()
        if scanning { scanMessage = "Scan stopped · \(devices.count) devices observed" }
        scanning = false
    }
    private func accept(_ device: LocalDevice) {
        var device = device
        device.isGateway = device.ip == connection.gateway
        device.isThisMac = device.ip == connection.ipv4
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index].merge(device) }
        else { devices.append(device) }
    }

    private func resolveNeighborNames(_ neighbors: [LocalDevice], interface: String, generation: UUID) async {
        await withTaskGroup(of: LocalDevice.self) { group in
            var next = 0
            func enqueue(_ device: LocalDevice) {
                group.addTask {
                    var device = device
                    if let name = await LocalDiscovery.reverseName(ip: device.ip, interface: interface) {
                        device.name = name; device.evidence = "Multicast DNS name"
                    }
                    return device
                }
            }
            let pending = devices.filter { candidate in !devices.contains(where: { $0.ip == candidate.ip && $0.name != nil }) }
            while next < min(16, pending.count) { enqueue(pending[next]); next += 1 }
            while let device = await group.next() {
                guard !Task.isCancelled, generation == scanGeneration else { group.cancelAll(); return }
                accept(device)
                if next < pending.count { enqueue(pending[next]); next += 1 }
            }
        }
    }

    private func startBonjour(generation: UUID) {
        for type in Self.serviceTypes {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: parameters)
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.scanGeneration == generation else { return }
                    switch state {
                    case .waiting(let error), .failed(let error):
                        if case .dns(let code) = error, code == -65570 {
                            self.discoveryError = "Allow Breeze in System Settings → Privacy & Security → Local Network, then scan again."
                        } else { self.discoveryError = "Some Bonjour discovery is unavailable: \(error.localizedDescription)" }
                    default: break
                    }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    guard let self, self.scanGeneration == generation else { return }
                    for result in results { self.resolve(result, type: type, generation: generation) }
                }
            }
            browsers.append(browser); browser.start(queue: .main)
        }
    }

    private func resolve(_ result: NWBrowser.Result, type: String, generation: UUID) {
        guard case .service(let name, _, let domain, _) = result.endpoint,
              result.interfaces.contains(where: { $0.name == connection.interface }),
              let subnet, resolvers.count < 64 else { return }
        let key = result.endpoint.debugDescription
        guard resolvers[key] == nil else { return }
        let interface = connection.interface
        resolvers[key] = Task { [weak self] in
            let devices = await LocalDiscovery.resolveService(name: name, type: type, domain: domain,
                                                               interface: interface, subnet: subnet)
            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            devices.forEach(self.accept)
        }
    }
    private func finishBonjour() {
        browsers.forEach { $0.cancel() }; browsers = []
        resolvers.values.forEach { $0.cancel() }; resolvers = [:]
    }
}
