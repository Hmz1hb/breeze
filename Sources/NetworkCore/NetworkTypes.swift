import Foundation

public struct NetworkCounters: Sendable, Equatable {
    public var received: UInt64
    public var sent: UInt64
    public init(received: UInt64, sent: UInt64) { self.received = received; self.sent = sent }
}

public struct NetworkTraffic: Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let download: Double
    public let upload: Double

    public static func sample(previous: NetworkCounters, current: NetworkCounters, elapsed: TimeInterval,
                              date: Date = .now) -> Self? {
        guard elapsed > 0, elapsed.isFinite, current.received >= previous.received, current.sent >= previous.sent else { return nil }
        return Self(date: date, download: Double(current.received - previous.received) / elapsed,
                    upload: Double(current.sent - previous.sent) / elapsed)
    }
}

public struct NetworkConnection: Sendable, Equatable {
    public var interface = ""
    public var name = "No active connection"
    public var kind = "Unknown"
    public var isUp = false
    public var ipv4: String?
    public var ipv6: [String] = []
    public var netmask: String?
    public var gateway: String?
    public var dns: [String] = []
    public var mac: String?
    public var ssid: String?
    public var standard: String?
    public var security: String?
    public var channel: String?
    public var signal: Int?
    public var noise: Int?
    public var linkMbps: Double?
    public init() {}
    public var identity: String { [interface, ipv4 ?? "", gateway ?? "", ssid ?? ""].joined(separator: "|") }
}

/// IPv4 arithmetic is kept separate from I/O so a scan can never escape its on-link subnet.
public struct LocalSubnet: Sendable, Equatable {
    public let address: UInt32
    public let mask: UInt32
    public var network: UInt32 { address & mask }
    public var broadcast: UInt32 { network | ~mask }
    public var prefix: Int { mask.nonzeroBitCount }
    public var cidr: String { "\(Self.string(network))/\(prefix)" }

    public init?(address: String, netmask: String) {
        guard let ip = Self.number(address), let mask = Self.number(netmask), mask != 0 else { return nil }
        let inverted = ~mask
        guard inverted & (inverted &+ 1) == 0 else { return nil }
        // Discovery targets private and link-local networks, never public address ranges.
        guard ip >> 24 == 10 || ip >> 20 == 0xAC1 || ip >> 16 == 0xC0A8 || ip >> 16 == 0xA9FE else { return nil }
        self.address = ip; self.mask = mask
    }

    public func contains(_ text: String) -> Bool {
        guard let ip = Self.number(text) else { return false }
        return ip & mask == network && ip > network && ip < broadcast
    }

    /// Limit large LANs to this Mac's /24. Preserve the real boundaries on /25…/30 LANs.
    public var targets: [String] {
        guard prefix <= 30 else { return [] }
        let lower = max(network &+ 1, address & 0xFFFFFF00)
        let upper = min(broadcast &- 1, (address & 0xFFFFFF00) | 255)
        guard lower <= upper else { return [] }
        return (lower...upper).filter { $0 != address }.map(Self.string)
    }
    public var isLimited: Bool { prefix < 24 }

    public static func number(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }
    public static func string(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }
}

public struct LocalDevice: Sendable, Identifiable, Equatable {
    public var id: String { ip }
    public var ip: String
    public var mac: String?
    public var name: String?
    public var model: String?
    public var manufacturer: String?
    public var services: [String] = []
    public var evidence: String
    public var responded = false
    public var isThisMac = false
    public var isGateway = false
    public var lastSeen = Date.now
    public init(ip: String, mac: String? = nil, name: String? = nil, evidence: String = "Neighbor record") {
        self.ip = ip; self.mac = mac; self.name = name; self.evidence = evidence
    }
    public var hasPrivateMAC: Bool {
        guard let first = mac?.split(separator: ":").first, let byte = UInt8(first, radix: 16) else { return false }
        return byte & 2 != 0
    }
    public var category: String {
        if isThisMac { return "This Mac" }
        if isGateway { return "Router" }
        let identity = [model, name].compactMap { $0 }.joined(separator: " ").lowercased()
        if identity.contains("iphone") { return "iPhone" }
        if identity.contains("ipad") { return "iPad" }
        if identity.contains("ipod") { return "iPod" }
        if identity.contains("appletv") || identity.contains("apple tv") { return "Apple TV" }
        if identity.contains("homepod") || identity.contains("audioaccessory") { return "HomePod" }
        if identity.contains("macbook") || identity.contains("imac") || identity.contains("macmini") || identity.contains("macpro") || identity.contains("macstudio") { return "Mac" }
        if services.contains(where: { $0.contains("ipp") || $0.contains("printer") }) { return "Printer" }
        if services.contains("_apple-mobdev2._tcp") || services.contains("_remotepairing._tcp") { return "Apple mobile device" }
        if services.contains(where: { $0.contains("airplay") || $0.contains("googlecast") }) { return "Media device" }
        if services.contains(where: { $0.contains("smb") || $0.contains("workstation") || $0.contains("ssh") }) { return "Computer / NAS" }
        // A private address is a hint, not proof: phones, tablets, watches and newer laptops all use them.
        if hasPrivateMAC && services.isEmpty { return "Private Wi-Fi device" }
        return "Unidentified device"
    }
    public var symbol: String {
        switch category {
        case "This Mac": "laptopcomputer"
        case "Router": "wifi.router"
        case "iPhone", "iPod", "Apple mobile device": "iphone"
        case "Private Wi-Fi device": "iphone.radiowaves.left.and.right"
        case "iPad": "ipad"
        case "Apple TV": "appletv"
        case "HomePod": "homepod"
        case "Mac": "desktopcomputer"
        case "Printer": "printer"
        case "Media device": "tv"
        case "Computer / NAS": "desktopcomputer"
        default: "network"
        }
    }
    public mutating func merge(_ other: Self) {
        guard ip == other.ip else { return }
        mac = other.mac ?? mac
        // A friendly hostname is more useful than a service's opaque pairing ID.
        if let incoming = other.name, name == nil || Self.nameQuality(incoming) > Self.nameQuality(name!) { name = incoming }
        model = other.model ?? model; manufacturer = other.manufacturer ?? manufacturer
        services = Array(Set(services + other.services)).sorted()
        responded = responded || other.responded
        isThisMac = isThisMac || other.isThisMac; isGateway = isGateway || other.isGateway
        if other.responded || evidence == "Neighbor record" { evidence = other.evidence }
        lastSeen = max(lastSeen, other.lastSeen)
    }

    private static func nameQuality(_ name: String) -> Int {
        let lower = name.lowercased()
        if ["iphone", "ipad", "ipod", "mac", "homepod", "apple tv"].contains(where: lower.contains) { return 2 }
        let compact = lower.filter { $0 != "-" && $0 != ":" }
        return compact.count >= 24 && compact.allSatisfy(\.isHexDigit) ? 0 : 1
    }
}

public enum NetworkMetrics {
    /// Mean absolute difference between consecutive successful TCP round trips.
    /// Missing probes break the chain rather than comparing across an outage.
    public static func jitter(_ milliseconds: [Double?]) -> Double? {
        let changes = zip(milliseconds, milliseconds.dropFirst()).compactMap { left, right -> Double? in
            guard let left, let right else { return nil }
            return abs(right - left)
        }
        return changes.isEmpty ? nil : changes.reduce(0, +) / Double(changes.count)
    }
}
