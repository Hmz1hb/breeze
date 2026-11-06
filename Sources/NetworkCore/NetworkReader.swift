import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

public enum NetworkReader {
    @concurrent public static func connection() async -> NetworkConnection {
        var result = NetworkConnection()
        guard let store = SCDynamicStoreCreate(nil, "Breeze Network" as CFString, nil, nil) else { return result }
        func state(_ key: String) -> [String: Any] {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
        }
        let global4 = state("State:/Network/Global/IPv4")
        let global6 = state("State:/Network/Global/IPv6")
        guard let name = (global4["PrimaryInterface"] ?? global6["PrimaryInterface"]) as? String else { return result }
        result.interface = name
        result.name = name
        result.gateway = (global4["Router"] ?? global6["Router"]) as? String
        let ipv4 = state("State:/Network/Interface/\(name)/IPv4")
        result.ipv4 = (ipv4["Addresses"] as? [String])?.first
        result.netmask = (ipv4["SubnetMasks"] as? [String])?.first
        result.ipv6 = state("State:/Network/Interface/\(name)/IPv6")["Addresses"] as? [String] ?? []
        result.dns = state("State:/Network/Global/DNS")["ServerAddresses"] as? [String] ?? []
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
           let item = interfaces.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == name }) {
            result.name = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? ?? name
            result.mac = SCNetworkInterfaceGetHardwareAddressString(item) as String?
            let type = SCNetworkInterfaceGetInterfaceType(item) as String? ?? "Unknown"
            result.kind = type == kSCNetworkInterfaceTypeIEEE80211 as String ? "Wi-Fi"
                : type == kSCNetworkInterfaceTypeEthernet as String ? "Ethernet" : type
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let start = list {
            defer { freeifaddrs(start) }
            for entry in sequence(first: start, next: { $0.pointee.ifa_next }) {
                guard String(cString: entry.pointee.ifa_name) == name else { continue }
                let flags = entry.pointee.ifa_flags
                result.isUp = flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0
            }
        }
        if let wifi = CWWiFiClient.shared().interface(withName: name), wifi.serviceActive() {
            result.kind = "Wi-Fi"
            result.ssid = wifi.ssid()
            result.mac = wifi.hardwareAddress() ?? result.mac
            let signal = wifi.rssiValue(), noise = wifi.noiseMeasurement()
            result.signal = signal < 0 ? signal : nil
            result.noise = noise < 0 ? noise : nil
            let rate = wifi.transmitRate()
            result.linkMbps = rate > 0 ? rate : nil
            let standards = [1: "802.11a", 2: "802.11b", 3: "802.11g", 4: "802.11n", 5: "802.11ac", 6: "802.11ax", 7: "802.11be"]
            result.standard = standards[wifi.activePHYMode().rawValue]
            let securities = [0: "Open", 1: "WEP", 2: "WPA Personal", 3: "WPA/WPA2 Personal", 4: "WPA2 Personal",
                              5: "Personal", 6: "Dynamic WEP", 7: "WPA Enterprise", 8: "WPA/WPA2 Enterprise",
                              9: "WPA2 Enterprise", 10: "Enterprise", 11: "WPA3 Personal", 12: "WPA3 Enterprise",
                              13: "WPA2/WPA3 Personal", 14: "Enhanced Open", 15: "Enhanced Open transition"]
            result.security = securities[wifi.security().rawValue]
            if let channel = wifi.wlanChannel() {
                let band = [1: "2.4 GHz", 2: "5 GHz", 3: "6 GHz"][channel.channelBand.rawValue]
                let width = [1: "20 MHz", 2: "40 MHz", 3: "80 MHz", 4: "160 MHz", 5: "320 MHz"][channel.channelWidth.rawValue]
                result.channel = ([String(channel.channelNumber)] + [band, width].compactMap { $0 }).joined(separator: " · ")
            }
        }
        return result
    }

    /// NET_RT_IFLIST2 exposes 64-bit counters, unlike getifaddrs' 32-bit if_data.
    @concurrent public static func counters(interface: String) async -> NetworkCounters? {
        let index = if_nametoindex(interface)
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        return bytes.withUnsafeMutableBytes { buffer in
            guard sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0 else { return nil }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0, offset + length <= size else { break }
                if header.ifm_type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let full = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(full.ifm_index) == index {
                        return NetworkCounters(received: full.ifm_data.ifi_ibytes, sent: full.ifm_data.ifi_obytes)
                    }
                }
                offset += length
            }
            return nil
        }
    }
}
