import Foundation
import NetworkCore
import Testing

@Test func trafficUsesElapsedTimeAndRejectsResetCounters() throws {
    let old = NetworkCounters(received: 8_000_000_000, sent: 5_000_000_000)
    let new = NetworkCounters(received: 8_000_004_000, sent: 5_000_001_000)
    let sample = try #require(NetworkTraffic.sample(previous: old, current: new, elapsed: 2))
    #expect(sample.download == 2000)
    #expect(sample.upload == 500)
    #expect(NetworkTraffic.sample(previous: new, current: old, elapsed: 2) == nil)
    #expect(NetworkTraffic.sample(previous: old, current: new, elapsed: 0) == nil)
    #expect(NetworkTraffic.sample(previous: old, current: new, elapsed: .nan) == nil)
}

@Test func sweepRespectsSubnetAndBoundsLargeNetworks() throws {
    let small = try #require(LocalSubnet(address: "192.168.1.132", netmask: "255.255.255.248"))
    #expect(small.cidr == "192.168.1.128/29")
    #expect(small.targets == ["192.168.1.129", "192.168.1.130", "192.168.1.131", "192.168.1.133", "192.168.1.134"])
    #expect(small.targets.allSatisfy(small.contains))
    let large = try #require(LocalSubnet(address: "10.20.30.40", netmask: "255.255.0.0"))
    #expect(large.targets.count <= 255)
    #expect(large.targets.allSatisfy { $0.hasPrefix("10.20.30.") && large.contains($0) })
    #expect(large.isLimited)
    #expect(LocalSubnet(address: "8.8.8.8", netmask: "255.255.255.0") == nil)
    #expect(LocalSubnet(address: "192.168.1.1", netmask: "255.0.255.0") == nil)
    #expect(LocalSubnet.number("192..1.1") == nil)
    #expect(LocalSubnet.number("256.1.1.1") == nil)
    #expect(LocalSubnet(address: "192.168.1.1", netmask: "255.255.255.255")?.targets.isEmpty == true)
}

@Test func neighborParsingRejectsIncompleteAndOutOfSubnetRecords() throws {
    let subnet = try #require(LocalSubnet(address: "192.168.1.20", netmask: "255.255.255.0"))
    let devices = LocalDiscovery.parseNeighbors("""
    ? (192.168.1.1) at 0:1a:2b:3:4:5 on en0 ifscope [ethernet]
    ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]
    ? (10.0.0.2) at 0:1a:2b:3:4:6 on en0 ifscope [ethernet]
    ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
    """, subnet: subnet)
    #expect(devices.count == 1)
    #expect(devices.first?.mac == "00:1a:2b:03:04:05")
}

@Test func deviceEvidenceMergesWithoutLosingIdentity() {
    var device = LocalDevice(ip: "192.168.1.9", mac: "02:01:02:03:04:05")
    var advertised = LocalDevice(ip: device.ip, name: "Office printer", evidence: "Bonjour")
    advertised.services = ["_ipp._tcp"]
    advertised.responded = true
    device.merge(advertised)
    #expect(device.name == "Office printer")
    #expect(device.category == "Printer")
    #expect(device.hasPrivateMAC)
    #expect(device.responded)
    #expect(device.evidence == "Bonjour")
    device.merge(LocalDevice(ip: "192.168.1.99", name: "Other device"))
    #expect(device.name == "Office printer")
}

@Test func jitterDoesNotBridgeAnOutage() {
    #expect(NetworkMetrics.jitter([10, 14, 12]) == 3)
    #expect(NetworkMetrics.jitter([10, nil, 30]) == nil)
    #expect(NetworkMetrics.jitter([]) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BREEZE_NETWORK_LIVE"] == "1"))
func liveNetworkReadsInterfaceCountersAndGatewayNeighbor() async throws {
    let connection = await NetworkReader.connection()
    #expect(connection.isUp)
    #expect(!connection.interface.isEmpty)
    let counters = await NetworkReader.counters(interface: connection.interface)
    #expect(counters != nil)
    let ip = try #require(connection.ipv4), mask = try #require(connection.netmask)
    let subnet = try #require(LocalSubnet(address: ip, netmask: mask))
    let neighbors = await LocalDiscovery.neighbors(interface: connection.interface, subnet: subnet)
    let gateway = try #require(neighbors.first { $0.ip == connection.gateway })
    #expect(gateway.mac != nil)
    #expect(neighbors.allSatisfy { subnet.contains($0.ip) })
}

@Test func appleDevicesUseAdvertisedModelsAndNames() {
    var phone = LocalDevice(ip: "192.168.1.10", name: "Mina’s iPhone.local.")
    #expect(phone.category == "iPhone")
    #expect(phone.symbol == "iphone")
    phone.name = "Mina’s phone"
    phone.model = "iPhone17,2"
    phone.services = ["_companion-link._tcp", "_airplay._tcp"]
    #expect(phone.category == "iPhone")
    phone.model = "iPad14,3"
    #expect(phone.category == "iPad")
    phone.model = "MacBookPro18,1"
    #expect(phone.category == "Mac")
}

@Test func appleServiceAloneDoesNotClaimAnIPhone() {
    var device = LocalDevice(ip: "192.168.1.10", mac: "02:01:02:03:04:05")
    device.services = ["_companion-link._tcp"]
    #expect(device.category == "Unidentified device")
    device.services.append("_apple-mobdev2._tcp")
    #expect(device.category == "Apple mobile device")
    device.name = "Office iPad"
    #expect(device.category == "iPad")
}

@Test func opaqueServiceNamesDoNotReplaceFriendlyPhoneNames() {
    var phone = LocalDevice(ip: "192.168.1.10", name: "Mina-iPhone")
    var service = LocalDevice(ip: phone.ip, name: "0123456789abcdef0123456789abcdef", evidence: "Bonjour advertisement")
    service.model = "iPhone17,2"
    phone.merge(service)
    #expect(phone.name == "Mina-iPhone")
    #expect(phone.model == "iPhone17,2")
    #expect(phone.category == "iPhone")
}

@Test func speedReportUsesMegabitsAndOptionalLatency() throws {
    let result = try InternetSpeedResult.parse(Data("""
    {"dl_throughput": 125000000, "ul_throughput": 24500000, "base_rtt": 12.5, "responsiveness": 1500, "future_field": true}
    """.utf8))
    #expect(result.downloadMbps == 125)
    #expect(result.uploadMbps == 24.5)
    #expect(result.idleLatency == 12.5)
    #expect(result.responsiveness == 1500)
    let minimal = try InternetSpeedResult.parse(Data("""
    {"dl_throughput": 1000000, "ul_throughput": 500000, "base_rtt": 0}
    """.utf8))
    #expect(minimal.downloadMbps == 1)
    #expect(minimal.idleLatency == nil)
}

@Test(arguments: [
    "{}",
    "{\"dl_throughput\": 0, \"ul_throughput\": 1000000}",
    "{\"dl_throughput\": -1, \"ul_throughput\": 1000000}",
    "{\"dl_throughput\": 1000000}",
    "{\"dl_throughput\": 1000000, \"ul_throughput\": 1000000, \"error\": {\"code\": -1009}}",
    "{\"dl_throughput\": 1000000, \"ul_throughput\": 1000000, \"error\": \"unavailable\"}",
    "not JSON"
])
func speedReportRejectsFailedAndIncompleteTests(report: String) {
    #expect(throws: (any Error).self) { try InternetSpeedResult.parse(Data(report.utf8)) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BREEZE_SPEED_LIVE"] == "1"))
@MainActor func liveSpeedTestCancelsAndThenMeasuresConnection() async throws {
    let connection = await NetworkReader.connection()
    let cancelled = Task { try await InternetSpeedTest.run(interface: connection.interface) }
    try await Task.sleep(for: .seconds(1))
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        Issue.record("A cancelled speed test returned a result")
    } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    let result = try await InternetSpeedTest.run(interface: connection.interface)
    #expect(result.downloadMbps > 0)
    #expect(result.uploadMbps > 0)
}
