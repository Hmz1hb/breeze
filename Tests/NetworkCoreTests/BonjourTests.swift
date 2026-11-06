import Darwin
import Foundation
import NetworkCore
import Testing
import dnssd

@Test(.enabled(if: ProcessInfo.processInfo.environment["BREEZE_BONJOUR_LIVE"] == "1"))
@concurrent func bonjourResolvesAnAdvertisementWithoutAnOpenTCPPort() async throws {
    let connection = await NetworkReader.connection()
    let ip = try #require(connection.ipv4)
    let mask = try #require(connection.netmask)
    let subnet = try #require(LocalSubnet(address: ip, netmask: mask))
    let name = "Breeze-fixture-\(UUID().uuidString.prefix(8))-iPhone"
    let txt = Array("model=iPhone17,2".utf8)
    let record = [UInt8(txt.count)] + txt
    let registered = RegistrationResult()
    var reference: DNSServiceRef?
    let status = record.withUnsafeBytes { buffer in
        DNSServiceRegister(&reference, 0, if_nametoindex(connection.interface), name, "_companion-link._tcp", "local.",
                           nil, UInt16(9).bigEndian, UInt16(record.count), buffer.baseAddress, {
            _, _, error, _, _, _, context in
            if let context { Unmanaged<RegistrationResult>.fromOpaque(context).takeUnretainedValue().ready = error == kDNSServiceErr_NoError }
        }, Unmanaged.passUnretained(registered).toOpaque())
    }
    #expect(status == kDNSServiceErr_NoError)
    let service = try #require(reference)
    defer { DNSServiceRefDeallocate(service) }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    withExtendedLifetime(registered) {
        while !registered.ready, ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: DNSServiceRefSockFD(service), events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 50) > 0 { _ = DNSServiceProcessResult(service) }
        }
    }
    #expect(registered.ready)
    let devices = await LocalDiscovery.resolveService(name: name, type: "_companion-link._tcp", domain: "local.",
                                                       interface: connection.interface, subnet: subnet)
    let device = try #require(devices.first { $0.ip == connection.ipv4 })
    #expect(device.model == "iPhone17,2")
    #expect(device.category == "iPhone")
    #expect(device.responded)
}

private final class RegistrationResult { var ready = false }
