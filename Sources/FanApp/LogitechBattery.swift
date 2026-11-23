import Foundation
import IOKit.hid

/// Logitech mice and keyboards report battery over HID++ 2.0 rather than the Bluetooth battery
/// service, so macOS doesn't list them. Breeze sends read-only feature queries on Logitech's
/// vendor collection: 0xFF43 for direct Bluetooth LE, 0xFF00 for Unifying/Bolt receivers.
enum LogitechBattery {
    private static let vendor = 0x046D
    private static let unifiedBattery: UInt16 = 0x1004, batteryStatus: UInt16 = 0x1000, deviceName: UInt16 = 0x0005

    struct Reading: Sendable {
        var batteries: [DeviceBattery] = []
        /// Devices found but not queried because Input Monitoring isn't granted yet.
        var needsAccess: [String] = []
    }

    static var access: IOHIDAccessType { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) }

    /// Shows the system Input Monitoring prompt. Only call this after the user asked for it.
    static func requestAccess() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

    static func read() async -> Reading {
        // IOHID replies arrive on a run loop; keep that wait off the cooperative pool.
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: readBlocking()) }
        }
    }

    private static func readBlocking() -> Reading {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendor] as CFDictionary)
        // The manager is never opened: opening it would open every matched device, including keyboards.
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return Reading() }
        let allowed = access == kIOHIDAccessTypeGranted
        var result = Reading()
        for device in devices {
            let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]] ?? []
            let pages = Set(pairs.compactMap { $0[kIOHIDDeviceUsagePageKey] })
            let indexes: [UInt8]
            if pages.contains(0xFF43) { indexes = [0xFF] }
            else if pages.contains(0xFF00) { indexes = Array(1...6) }
            else { continue }
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech device"
            // macOS treats opening any HID device as Input Monitoring, mice included, so a background
            // read never opens one. The Battery page explains why before the user asks for the prompt.
            guard allowed else {
                if !result.needsAccess.contains(product) { result.needsAccess.append(product) }
                continue
            }
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
            let session = HIDPPSession(device: device)
            let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? product
            for index in indexes {
                guard let level = session.battery(index: index) else { continue }
                let name = index == 0xFF ? product : session.name(index: index) ?? "\(product) device \(index)"
                result.batteries.append(DeviceBattery(id: "logitech:\(serial):\(index)", name: name, kind: product, levels: [level]))
            }
            session.close()
        }
        return result
    }

    /// Parses HID++ unified battery (0x1004 get_status) or battery status (0x1000) parameters.
    static func level(feature: UInt16, parameters: [UInt8]) -> DeviceBattery.Level? {
        guard parameters.count >= 3 else { return nil }
        // 0x1004: 1 charging, 2 slow charging. 0x1000: 1 recharging, 2 almost full, 4 slow recharge.
        let charging = feature == unifiedBattery ? [1, 2].contains(parameters[2]) : [1, 2, 4].contains(parameters[2])
        var percent = Int(parameters[0])
        if feature == unifiedBattery, percent == 0 {
            // Devices without percentage support report only a level flag.
            switch parameters[1] {
            case let flags where flags & 8 != 0: percent = 90
            case let flags where flags & 4 != 0: percent = 50
            case let flags where flags & 2 != 0: percent = 20
            case let flags where flags & 1 != 0: percent = 5
            default: return nil
            }
        }
        guard (1...100).contains(percent) else { return nil }
        return DeviceBattery.Level(label: charging ? "Charging" : "", percent: percent)
    }

    private final class HIDPPSession {
        let device: IOHIDDevice
        private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        fileprivate var reply: [UInt8] = []

        init(device: IOHIDDevice) {
            self.device = device
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
                guard let context else { return }
                Unmanaged<HIDPPSession>.fromOpaque(context).takeUnretainedValue().reply = Array(UnsafeBufferPointer(start: report, count: length))
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        func close() {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            buffer.deallocate()
        }

        /// Sends a long (0x11) request and waits up to 1s for the matching reply. Errors (0xFF) return nil.
        func request(index: UInt8, feature: UInt8, function: UInt8, _ parameters: [UInt8] = []) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: 20)
            bytes[0] = 0x11; bytes[1] = index; bytes[2] = feature; bytes[3] = function << 4 | 0x0B
            for (offset, value) in parameters.prefix(16).enumerated() { bytes[4 + offset] = value }
            reply = []
            guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, bytes, bytes.count) == kIOReturnSuccess else { return nil }
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                CFRunLoopRunInMode(.defaultMode, 0.05, true)
                guard reply.count >= 7, reply[1] == index else { continue }
                if reply[2] == 0xFF || reply[2] == 0x8F { return nil }
                if reply[2] == feature, reply[3] == bytes[3] { return Array(reply[4...]) }
            }
            return nil
        }
        func featureIndex(_ feature: UInt16, index: UInt8) -> UInt8? {
            guard let answer = request(index: index, feature: 0, function: 0, [UInt8(feature >> 8), UInt8(feature & 0xFF)]),
                  let first = answer.first, first != 0 else { return nil }
            return first
        }
        func battery(index: UInt8) -> DeviceBattery.Level? {
            for feature in [LogitechBattery.unifiedBattery, LogitechBattery.batteryStatus] {
                guard let slot = featureIndex(feature, index: index) else { continue }
                let answer = request(index: index, feature: slot, function: feature == LogitechBattery.unifiedBattery ? 1 : 0)
                return answer.flatMap { LogitechBattery.level(feature: feature, parameters: $0) }
            }
            return nil
        }
        func name(index: UInt8) -> String? {
            guard let slot = featureIndex(LogitechBattery.deviceName, index: index),
                  let length = request(index: index, feature: slot, function: 0)?.first, length > 0 else { return nil }
            var bytes: [UInt8] = []
            while bytes.count < Int(length), let chunk = request(index: index, feature: slot, function: 1, [UInt8(bytes.count)]) {
                bytes += chunk.prefix(Int(length) - bytes.count)
                if chunk.isEmpty { break }
            }
            let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            return name.isEmpty ? nil : name
        }
    }
}
