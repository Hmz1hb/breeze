import Darwin
import Foundation
import dnssd

extension LocalDiscovery {
    /// Resolve DNS records without connecting to the advertised application port.
    /// Phones may advertise a service while rejecting an unauthenticated TCP connection.
    @concurrent public static func resolveService(name: String, type: String, domain: String,
                                                  interface: String, subnet: LocalSubnet) async -> [LocalDevice] {
        let index = if_nametoindex(interface)
        guard index != 0, domain.lowercased() == "local.", !Task.isCancelled else { return [] }
        let service = ServiceAnswer()
        var reference: DNSServiceRef?
        let status = DNSServiceResolve(&reference, 0, index, name, type, domain, {
            _, _, _, error, _, host, _, length, record, context in
            guard error == kDNSServiceErr_NoError, let host, let context else { return }
            let result = Unmanaged<ServiceAnswer>.fromOpaque(context).takeUnretainedValue()
            result.host = String(cString: host)
            if let record { result.txt = txtDictionary(record, length: length) }
        }, Unmanaged.passUnretained(service).toOpaque())
        guard status == kDNSServiceErr_NoError, let reference else { return [] }
        withExtendedLifetime(service) { processDNS(reference, timeout: 1.2) { service.host != nil } }
        DNSServiceRefDeallocate(reference)
        guard let host = service.host, host.lowercased().hasSuffix(".local."), !Task.isCancelled else { return [] }

        let addresses = AddressAnswer()
        var addressRef: DNSServiceRef?
        let addressStatus = DNSServiceGetAddrInfo(&addressRef, DNSServiceFlags(kDNSServiceFlagsForceMulticast), index,
                                                  DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, {
            _, flags, _, error, _, address, _, context in
            guard error == kDNSServiceErr_NoError, flags & UInt32(kDNSServiceFlagsAdd) != 0,
                  let address, address.pointee.sa_family == AF_INET, let context else { return }
            let result = Unmanaged<AddressAnswer>.fromOpaque(context).takeUnretainedValue()
            let ipv4 = UnsafeRawPointer(address).load(as: sockaddr_in.self)
            var ip = ipv4.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ip, &text, socklen_t(text.count)) != nil {
                result.addresses.insert(dnsString(text))
            }
        }, Unmanaged.passUnretained(addresses).toOpaque())
        guard addressStatus == kDNSServiceErr_NoError, let addressRef else { return [] }
        withExtendedLifetime(addresses) { processDNS(addressRef, timeout: 0.8) { !addresses.addresses.isEmpty } }
        DNSServiceRefDeallocate(addressRef)
        guard !Task.isCancelled else { return [] }
        let ips = addresses.addresses.filter(subnet.contains)
        guard !ips.isEmpty else { return [] }

        // Apple commonly publishes model information as a separate TXT record.
        // It need not have an SRV record, so resolving _device-info as a TCP service
        // alone would miss it.
        var txt = service.txt
        if txt["model"] == nil, txt["md"] == nil {
            let hostLabel = String(host.dropLast(".local.".count))
            for label in Set([name, hostLabel]) where !Task.isCancelled {
                var fullName = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
                if DNSServiceConstructFullName(&fullName, label, "_device-info._tcp", "local.") == 0 {
                    let info = queryTXT(dnsString(fullName), interface: index)
                    txt.merge(info, uniquingKeysWith: { current, _ in current })
                    if txt["model"] != nil { break }
                }
            }
        }
        return ips.map { ip in
            var device = LocalDevice(ip: ip, name: String(name.prefix(120)), evidence: "Bonjour advertisement")
            // Merge the hostname as well: mobile pairing services often use an opaque ID.
            device.merge(LocalDevice(ip: ip, name: String(host.dropLast(".local.".count).prefix(120)), evidence: device.evidence))
            device.services = [type]
            device.responded = true
            device.model = (txt["model"] ?? txt["md"] ?? txt["ty"]).map { String($0.prefix(120)) }
            device.manufacturer = (txt["manufacturer"] ?? txt["mfg"]).map { String($0.prefix(120)) }
            return device
        }
    }
}

private func txtDictionary(_ record: UnsafePointer<UInt8>, length: UInt16) -> [String: String] {
    var values: [String: String] = [:]
    for item in 0..<TXTRecordGetCount(length, record) {
        var key = [CChar](repeating: 0, count: 256)
        var valueLength: UInt8 = 0
        var value: UnsafeRawPointer?
        guard TXTRecordGetItemAtIndex(length, record, item, UInt16(key.count), &key, &valueLength, &value) == 0,
              let value else { continue }
        values[dnsString(key).lowercased()] = String(decoding: UnsafeRawBufferPointer(start: value, count: Int(valueLength)), as: UTF8.self)
    }
    return values
}

private func queryTXT(_ name: String, interface: UInt32) -> [String: String] {
    let answer = ServiceAnswer()
    var reference: DNSServiceRef?
    let status = DNSServiceQueryRecord(&reference, DNSServiceFlags(kDNSServiceFlagsForceMulticast), interface,
                                      name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN), {
        _, flags, _, error, _, _, _, length, data, _, context in
        guard error == kDNSServiceErr_NoError, flags & UInt32(kDNSServiceFlagsAdd) != 0,
              let data, let context else { return }
        let result = Unmanaged<ServiceAnswer>.fromOpaque(context).takeUnretainedValue()
        result.txt = txtDictionary(data.assumingMemoryBound(to: UInt8.self), length: length)
        result.host = "received"
    }, Unmanaged.passUnretained(answer).toOpaque())
    guard status == kDNSServiceErr_NoError, let reference else { return [:] }
    defer { DNSServiceRefDeallocate(reference) }
    withExtendedLifetime(answer) { processDNS(reference, timeout: 0.3) { answer.host != nil } }
    return answer.txt
}

private func processDNS(_ reference: DNSServiceRef, timeout: TimeInterval, complete: () -> Bool) {
    let descriptor = DNSServiceRefSockFD(reference)
    guard descriptor >= 0 else { return }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !Task.isCancelled, !complete(), ProcessInfo.processInfo.systemUptime < deadline {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&pollDescriptor, 1, 50)
        if result < 0 || pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { break }
        if result > 0, DNSServiceProcessResult(reference) != kDNSServiceErr_NoError { break }
    }
}

// Each box is owned by one invocation and used only by its synchronous DNS callback.
private final class ServiceAnswer { var host: String?; var txt: [String: String] = [:] }
private final class AddressAnswer { var addresses: Set<String> = [] }

private func dnsString(_ bytes: [CChar]) -> String {
    String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
