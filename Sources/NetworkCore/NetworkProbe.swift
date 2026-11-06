import Darwin
import Foundation
import dnssd

public struct NetworkProbeResult: Sendable {
    public let reachable: Bool
    public let milliseconds: Double?
    public let evidence: String
}

public enum NetworkProbe {
    /// A TCP handshake, measured with a monotonic clock. No application data is sent.
    @concurrent public static func tcp(host: String, port: UInt16 = 443, timeout: Int = 1500,
                                       interface: String? = nil, refusalIsReachable: Bool = false) async -> NetworkProbeResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .init(reachable: false, milliseconds: nil, evidence: "Socket unavailable") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        if let interface {
            var index = if_nametoindex(interface)
            guard index != 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0 else {
                return .init(reachable: false, milliseconds: nil, evidence: "Interface unavailable")
            }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .init(reachable: false, milliseconds: nil, evidence: "Invalid address") }
        let started = ProcessInfo.processInfo.systemUptime
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if status == 0 { return .init(reachable: true, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, evidence: "TCP response") }
        if errno != EINPROGRESS {
            return .init(reachable: refusalIsReachable && errno == ECONNREFUSED, milliseconds: nil, evidence: "TCP response")
        }
        let deadline = started + Double(timeout) / 1000
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready > 0 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { break }
                let reachable = error == 0 || (refusalIsReachable && error == ECONNREFUSED)
                return .init(reachable: reachable, milliseconds: reachable ? (ProcessInfo.processInfo.systemUptime - started) * 1000 : nil,
                             evidence: "TCP response")
            }
            if ready < 0 { break }
        }
        return .init(reachable: false, milliseconds: nil, evidence: Task.isCancelled ? "Cancelled" : "No response")
    }

    /// macOS allows unprivileged ICMP echo datagram sockets. No root helper is used.
    @concurrent public static func echo(host: String, interface: String, timeout: Int = 300) async -> Bool {
        guard !Task.isCancelled else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var index = if_nametoindex(interface)
        guard index != 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        let sequence = UInt16.random(in: 1...UInt16.max)
        var packet: [UInt8] = [8, 0, 0, 0, 0, 0, UInt8(sequence >> 8), UInt8(sequence & 255)]
        var sum: UInt32 = 0
        for offset in stride(from: 0, to: packet.count, by: 2) { sum += UInt32(packet[offset]) << 8 | UInt32(packet[offset + 1]) }
        while sum >> 16 != 0 { sum = (sum & 65535) + (sum >> 16) }
        let checksum = ~UInt16(sum)
        packet[2] = UInt8(checksum >> 8); packet[3] = UInt8(checksum & 255)
        guard packet.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == packet.count else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeout) / 1000
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 50) > 0 {
                var buffer = [UInt8](repeating: 0, count: 2048)
                let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
                guard count >= 8 else { continue }
                let offset = buffer[0] >> 4 == 4 ? Int(buffer[0] & 15) * 4 : 0
                if count >= offset + 8, buffer[offset] == 0,
                   buffer[offset + 6] == packet[6], buffer[offset + 7] == packet[7] { return true }
            }
        }
        return false
    }
}

public enum LocalDiscovery {
    @concurrent public static func sweep(subnet: LocalSubnet, interface: String,
                                         onProgress: @Sendable (Int, Int, LocalDevice?) async -> Void) async {
        let targets = subnet.targets
        await withTaskGroup(of: (String, String?).self) { group in
            var next = 0, completed = 0
            func enqueue(_ host: String) {
                group.addTask {
                    if await NetworkProbe.echo(host: host, interface: interface) { return (host, "ICMP reply") }
                    guard !Task.isCancelled else { return (host, nil) }
                    let tcp = await NetworkProbe.tcp(host: host, port: 80, timeout: 250, interface: interface, refusalIsReachable: true)
                    return (host, tcp.reachable ? "TCP response" : nil)
                }
            }
            while next < min(24, targets.count) { enqueue(targets[next]); next += 1 }
            while let (host, evidence) = await group.next() {
                if Task.isCancelled { group.cancelAll(); return }
                completed += 1
                var device = evidence.map { LocalDevice(ip: host, evidence: $0) }
                device?.responded = true
                await onProgress(completed, targets.count, device)
                if next < targets.count { enqueue(targets[next]); next += 1 }
            }
        }
    }

    @concurrent public static func neighbors(interface: String, subnet: LocalSubnet) async -> [LocalDevice] {
        guard !Task.isCancelled else { return [] }
        if let records = routeNeighbors(interface: interface, subnet: subnet) { return records }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an", "-i", interface]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if ProcessInfo.processInfo.environment["BREEZE_NETWORK_LIVE"] == "1" { print("arp result", process.terminationStatus, String(decoding: data, as: UTF8.self).prefix(300), "subnet", subnet.cidr) }
        guard process.terminationStatus == 0 else { return [] }
        return parseNeighbors(String(decoding: data, as: UTF8.self), subnet: subnet)
    }

    /// Read link-layer neighbors directly. Some GUI launch contexts cannot spawn
    /// arp, and the routing table avoids that subprocess dependency entirely.
    private static func routeNeighbors(interface: String, subnet: LocalSubnet) -> [LocalDevice]? {
        let index = if_nametoindex(interface)
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0, size < 16_777_216 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        return bytes.withUnsafeMutableBytes { buffer -> [LocalDevice]? in
            guard sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0 else { return nil }
            var devices: [LocalDevice] = [], offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= size {
                let header = buffer.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let end = offset + Int(header.rtm_msglen)
                if ProcessInfo.processInfo.environment["BREEZE_NETWORK_LIVE"] == "1", offset == 0 {
                    print("route layout", MemoryLayout<rt_msghdr>.size, "record", header.rtm_msglen, "interface", header.rtm_index, "wanted", index, "addresses", header.rtm_addrs)
                    print("route bytes", Array(buffer[(offset + MemoryLayout<rt_msghdr>.size)..<min(end, offset + MemoryLayout<rt_msghdr>.size + 48)]))
                }
                guard end > offset, end <= size else { break }
                defer { offset = end }
                guard UInt32(header.rtm_index) == index else { continue }
                var cursor = offset + MemoryLayout<rt_msghdr>.size
                var ip: String?, mac: String?
                for slot in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << slot) != 0 {
                    guard cursor + 2 <= end else { break }
                    let length = Int(buffer[cursor]), family = Int32(buffer[cursor + 1])
                    guard length >= 2, cursor + length <= end else { break }
                    if slot == RTAX_DST, family == AF_INET, length >= 8 {
                        ip = (4..<8).map { String(buffer[cursor + $0]) }.joined(separator: ".")
                    }
                    if slot == RTAX_GATEWAY, family == AF_LINK, length >= 8 {
                        let nameLength = Int(buffer[cursor + 5]), addressLength = Int(buffer[cursor + 6])
                        if addressLength == 6, 8 + nameLength + addressLength <= length {
                            mac = normalizedMAC((0..<6).map { String(format: "%02x", buffer[cursor + 8 + nameLength + $0]) }.joined(separator: ":"))
                        }
                    }
                    // Darwin routing messages align sockaddr records to 32 bits.
                    cursor += (length + 3) & ~3
                }
                if let ip, let mac, subnet.contains(ip) { devices.append(LocalDevice(ip: ip, mac: mac)) }
            }
            return devices
        }
    }

    /// A bounded, interface-scoped multicast PTR query. It never sends a local
    /// device address to an external reverse-DNS service.
    @concurrent public static func reverseName(ip: String, interface: String) async -> String? {
        guard LocalSubnet.number(ip) != nil, !Task.isCancelled else { return nil }
        let box = DNSNameResult()
        var reference: DNSServiceRef?
        let reverse = ip.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa."
        let status = DNSServiceQueryRecord(&reference, DNSServiceFlags(kDNSServiceFlagsForceMulticast), if_nametoindex(interface),
                                          reverse, UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN),
                                          { _, flags, _, error, _, _, _, length, data, _, context in
            guard error == kDNSServiceErr_NoError, flags & UInt32(kDNSServiceFlagsAdd) != 0,
                  let data, let context else { return }
            let result = Unmanaged<DNSNameResult>.fromOpaque(context).takeUnretainedValue()
            let bytes = UnsafeRawBufferPointer(start: data, count: Int(length))
            var parts: [String] = [], offset = 0
            while offset < bytes.count {
                let count = Int(bytes[offset]); offset += 1
                if count == 0 { break }
                guard count <= 63, offset + count <= bytes.count else { return }
                parts.append(String(decoding: bytes[offset..<(offset + count)], as: UTF8.self))
                offset += count
            }
            if !parts.isEmpty { result.name = String(parts.joined(separator: ".").prefix(120)) }
        }, Unmanaged.passUnretained(box).toOpaque())
        guard status == kDNSServiceErr_NoError, let reference else { return nil }
        defer { DNSServiceRefDeallocate(reference) }
        return withExtendedLifetime(box) {
            let descriptor = DNSServiceRefSockFD(reference)
            guard descriptor >= 0 else { return nil }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.6
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline, box.name == nil {
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                if poll(&pollDescriptor, 1, 50) > 0 {
                    if DNSServiceProcessResult(reference) != kDNSServiceErr_NoError { break }
                }
            }
            return box.name
        }
    }

    public static func parseNeighbors(_ text: String, subnet: LocalSubnet) -> [LocalDevice] {
        text.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 4, columns[2] == "at" else { return nil }
            let ip = String(columns[1]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard subnet.contains(ip), let mac = normalizedMAC(String(columns[3])) else { return nil }
            return LocalDevice(ip: ip, mac: mac)
        }
    }
    public static func normalizedMAC(_ text: String) -> String? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }), bytes[0] & 1 == 0 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

// Owned and accessed only by a single reverseName invocation and its synchronous
// DNSServiceProcessResult callback. It is never shared between Swift tasks.
private final class DNSNameResult { var name: String? }
