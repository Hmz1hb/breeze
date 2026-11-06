import Foundation
import IOKit

public struct DriveHealth: Sendable {
    public let status: String?
    public let temperature: Double?
    public let lifeRemaining: Int?
    public let lifetimeRead: Int64?
    public let lifetimeWritten: Int64?
    public let powerCycles: Double?
    public let powerOnHours: Double?
    public let unsafeShutdowns: Double?
    public let mediaErrors: Double?
    public let availableSpare: Int?
    public let criticalWarning: Int?

    // diskutil's device-specific dictionary is optional and varies by driver.
    // NVMe temperature is Kelvin; a data unit is 1,000 × 512 bytes.
    init(info: [String: Any]) {
        status = info["SMARTStatus"] as? String
        let values = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
        func counter(_ key: String) -> Double? {
            guard let low = number(key + "_0") else { return number(key) }
            return low + (number(key + "_1") ?? 0) * 18_446_744_073_709_551_616
        }
        func bytes(_ key: String) -> Int64? {
            guard let units = counter(key), units >= 0 else { return nil }
            let bytes = units * 512_000
            return bytes < Double(Int64.max) ? Int64(bytes) : nil
        }
        temperature = number("TEMPERATURE").flatMap { $0 > 0 ? $0 - 273.15 : nil }
        lifeRemaining = number("PERCENTAGE_USED").map { Int(max(0, 100 - min(100, $0))) }
        lifetimeRead = bytes("DATA_UNITS_READ")
        lifetimeWritten = bytes("DATA_UNITS_WRITTEN")
        powerCycles = counter("POWER_CYCLES")
        powerOnHours = counter("POWER_ON_HOURS")
        unsafeShutdowns = counter("UNSAFE_SHUTDOWNS")
        mediaErrors = counter("MEDIA_ERRORS")
        availableSpare = number("AVAILABLE_SPARE").map { Int(min(100, max(0, $0))) }
        criticalWarning = number("CRITICAL_WARNING").map { Int($0) }
    }
}

public struct StorageDrive: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let total: Int64
    public let free: Int64
    public let fileSystem: String
    public let device: String?
    public let physicalDevices: [String]
    public let model: String?
    public let connection: String?
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isStartup: Bool
    public let isSSD: Bool?
    public let encrypted: Bool?
    public let writable: Bool?
    public let container: String?
    public let health: DriveHealth
    public var used: Int64 { max(0, total - free) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct DriveCounters: Sendable {
    public let read: UInt64
    public let written: UInt64
    public let readOperations: UInt64
    public let writeOperations: UInt64
}

public struct DriveActivity: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let readRate: Double
    public let writeRate: Double
    public let readIOPS: Double
    public let writeIOPS: Double

    public static func sample(previous: DriveCounters, current: DriveCounters,
                              elapsed: TimeInterval, date: Date = .now) -> DriveActivity? {
        guard elapsed > 0, elapsed < 10,
              current.read >= previous.read, current.written >= previous.written,
              current.readOperations >= previous.readOperations,
              current.writeOperations >= previous.writeOperations else { return nil }
        return DriveActivity(date: date, readRate: Double(current.read - previous.read) / elapsed,
                             writeRate: Double(current.written - previous.written) / elapsed,
                             readIOPS: Double(current.readOperations - previous.readOperations) / elapsed,
                             writeIOPS: Double(current.writeOperations - previous.writeOperations) / elapsed)
    }
}

public enum StorageDriveReader {
    /// Refresh metadata separately from lightweight two-second driver samples.
    @concurrent public static func volumes() async -> [StorageDrive] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey]
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                            options: .skipHiddenVolumes) ?? []
        let urls = [root] + mounted.filter { $0.path != "/" && !$0.path.hasPrefix("/System/") && !$0.path.hasPrefix("/private/") }
        var result: [StorageDrive] = []
        var physicalInfo: [String: [String: Any]] = [:]
        for url in urls {
            guard !Task.isCancelled else { break }
            guard let resources = try? url.resourceValues(forKeys: keys), resources.volumeIsLocal != false else { continue }
            let startup = url.path == "/"
            // The signed system snapshot is read-only. Query the paired Data volume
            // for encryption and write access, while keeping one startup-disk entry.
            let info = diskInfo(startup ? "/System/Volumes/Data" : url.path)
            let device = info["DeviceIdentifier"] as? String
            let stores = info["APFSPhysicalStores"] as? [[String: Any]] ?? []
            let physical = stores.compactMap { $0["APFSPhysicalStore"] as? String }
                .map(wholeDisk)
            let devices = physical.isEmpty ? (info["ParentWholeDisk"] as? String).map { [$0] } ?? [] : physical
            for disk in devices where physicalInfo[disk] == nil { physicalInfo[disk] = diskInfo(disk) }
            let hardware = devices.count == 1 ? devices.first.flatMap { physicalInfo[$0] } ?? [:] : [:]
            let total = (info["APFSContainerSize"] as? NSNumber)?.int64Value
                ?? resources.volumeTotalCapacity.map(Int64.init) ?? 0
            let available = (info["APFSContainerFree"] as? NSNumber)?.int64Value
                ?? resources.volumeAvailableCapacity.map(Int64.init) ?? 0
            guard total > 0 else { continue }
            result.append(StorageDrive(id: url.path, name: resources.volumeName ?? url.lastPathComponent,
                url: url, total: total, free: min(total, max(0, available)),
                fileSystem: info["FilesystemName"] as? String ?? resources.volumeLocalizedFormatDescription ?? "Unknown",
                device: device, physicalDevices: devices, model: hardware["MediaName"] as? String,
                connection: info["BusProtocol"] as? String ?? hardware["BusProtocol"] as? String,
                isInternal: info["Internal"] as? Bool ?? resources.volumeIsInternal ?? false,
                isRemovable: info["Removable"] as? Bool ?? resources.volumeIsRemovable ?? false,
                isStartup: startup, isSSD: hardware["SolidState"] as? Bool ?? info["SolidState"] as? Bool,
                encrypted: info["FileVault"] as? Bool ?? info["Encryption"] as? Bool,
                writable: info["WritableVolume"] as? Bool ?? resources.volumeIsReadOnly.map { !$0 },
                container: info["APFSContainerReference"] as? String,
                health: DriveHealth(info: devices.count > 1 ? [:] : hardware.isEmpty ? info : hardware)))
        }
        return result.sorted { a, b in a.isStartup != b.isStartup ? a.isStartup : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    static func wholeDisk(_ partition: String) -> String {
        guard let range = partition.range(of: #"^disk[0-9]+"#, options: .regularExpression) else { return partition }
        return String(partition[range])
    }

    private static func diskInfo(_ path: String) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
        } catch { return [:] }
    }

    @concurrent public static func counters() async -> [String: DriveCounters] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: DriveCounters] = [:]
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: NSNumber] else { continue }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let media = IOIteratorNext(children), media != 0 {
                defer { IOObjectRelease(media) }
                guard let name = IORegistryEntryCreateCFProperty(media, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                      let read = statistics["Bytes (Read)"]?.uint64Value,
                      let written = statistics["Bytes (Write)"]?.uint64Value else { continue }
                result[name] = DriveCounters(read: read, written: written,
                    readOperations: statistics["Operations (Read)"]?.uint64Value ?? 0,
                    writeOperations: statistics["Operations (Write)"]?.uint64Value ?? 0)
            }
        }
        return result
    }
}
