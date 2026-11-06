import AppKit
import Darwin
import IOKit
import Observation
import UniformTypeIdentifiers

/// Optional readings stay optional: a missing property must never become a made-up specification.
struct MacHardwareInfo: Sendable {
    var modelIdentifier: String?
    var family: String?
    var processor: String?
    var physicalCores: Int?
    var logicalCores: Int?
    var performanceCores: Int?
    var efficiencyCores: Int?
    var memory: String?
    var graphics: [String] = []
    var serialNumber: String?
    var disks: [String] = []

    static func parse(_ data: Data) throws -> MacHardwareInfo {
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let hardware = (report["SPHardwareDataType"] as? [[String: Any]])?.first ?? [:]
        var info = MacHardwareInfo()
        info.modelIdentifier = hardware["machine_model"] as? String
        info.family = hardware["machine_name"] as? String
        info.processor = hardware["chip_type"] as? String ?? hardware["cpu_type"] as? String
        info.memory = hardware["physical_memory"] as? String
        info.serialNumber = hardware["serial_number"] as? String
        // system_profiler encodes Apple silicon as "proc total:0:performance:efficiency".
        // Intel reports "N processors, M cores"; do not interpret those as hybrid cores.
        if let raw = hardware["number_processors"] as? String, raw.hasPrefix("proc ") {
            let counts = raw.dropFirst(5).split(separator: ":").compactMap { Int($0) }
            if counts.count == 4 {
                info.physicalCores = counts[0]
                if counts[2] > 0 { info.performanceCores = counts[2] }
                if counts[3] > 0 { info.efficiencyCores = counts[3] }
            }
        }
        info.graphics = (report["SPDisplaysDataType"] as? [[String: Any]] ?? []).compactMap { gpu in
            guard let name = gpu["sppci_model"] as? String ?? gpu["_name"] as? String else { return nil }
            let cores = (gpu["sppci_cores"] as? String).flatMap(Int.init)
                ?? (gpu["sppci_cores"] as? NSNumber)?.intValue
            return cores.map { "\(name) (\($0) cores)" } ?? name
        }
        return info
    }

    var processorLines: [String] {
        var lines = [processor ?? "Unavailable"]
        if let physicalCores, let logicalCores {
            lines.append("\(physicalCores) cores, \(logicalCores) threads")
        } else if let physicalCores { lines.append("\(physicalCores) cores") }
        if let efficiencyCores { lines.append("\(efficiencyCores) efficiency cores") }
        if let performanceCores { lines.append("\(performanceCores) performance cores") }
        return lines
    }
}

struct MacModelIdentity {
    let contentType: UTType?
    let size: String?
    let year: String?

    init(modelIdentifier: String?) {
        let type = modelIdentifier.flatMap {
            UTType(tag: $0, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
        }
        // A dynamic type means Launch Services has no matching model in its catalog.
        contentType = type?.isDynamic == false ? type : nil
        let parts = contentType?.identifier.split(separator: "-").map(String.init) ?? []
        year = parts.first { $0.count == 4 && Int($0).map { (1984...2100).contains($0) } == true }
        // The catalog uses whole-inch marketing sizes for MacBook and iMac models.
        size = parts.dropFirst().first { Int($0).map { (11...32).contains($0) } == true }
    }

    func title(family: String?, processor: String?) -> String {
        var name = family ?? contentType?.localizedDescription ?? "Mac"
        if let size { name += " \(size)″" }
        if let processor, processor.hasPrefix("Apple ") {
            name += " (\(processor.dropFirst(6)))"
        }
        return name
    }
}

enum MacInfoReader {
    @concurrent static func read() async -> MacHardwareInfo {
        var info = (try? MacHardwareInfo.parse(profile())) ?? MacHardwareInfo()
        if info.modelIdentifier == nil { info.modelIdentifier = platformString("model") }
        if info.serialNumber == nil { info.serialNumber = platformString("IOPlatformSerialNumber") }
        if info.processor == nil { info.processor = sysctlString("machdep.cpu.brand_string") }
        info.physicalCores = sysctlInt("hw.physicalcpu") ?? info.physicalCores
        info.logicalCores = sysctlInt("hw.logicalcpu")
        // perflevel 0 is performance; perflevel 1 is efficiency on hybrid Apple silicon.
        if sysctlInt("hw.nperflevels").map({ $0 > 1 }) == true {
            info.performanceCores = sysctlInt("hw.perflevel0.physicalcpu") ?? info.performanceCores
            info.efficiencyCores = sysctlInt("hw.perflevel1.physicalcpu") ?? info.efficiencyCores
        }
        if info.memory == nil {
            info.memory = "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB"
        }
        info.disks = disks()
        return info
    }

    private static func profile() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-detailLevel", "mini", "-timeout", "10", "SPHardwareDataType", "SPDisplaysDataType"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    private static func platformString(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        if let value = value as? String { return value }
        if let data = value as? Data { return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) }
        return nil
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctlbyname(key, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
    }

    private static func sysctlInt(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    private static func disks() -> [String] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeIsLocalKey]
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: .skipHiddenVolumes) ?? []
        let urls = [root] + mounted.filter { $0.path != "/" && !$0.path.hasPrefix("/System/") && !$0.path.hasPrefix("/private/") }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal == true,
                  let capacity = values.volumeTotalCapacity, capacity > 0 else { return nil }
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(capacity), countStyle: .decimal)
            return "\(values.volumeName ?? url.lastPathComponent) (\(formatted))"
        }
    }
}

@MainActor @Observable
final class MacInfoModel {
    var hardware = MacHardwareInfo()
    var identity = MacModelIdentity(modelIdentifier: nil)
    var image: NSImage?
    var displays: [String] = []
    var loading = false
    var loaded = false

    var title: String { identity.title(family: hardware.family, processor: hardware.processor) }
    var operatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion == 0 ? "" : ".\(version.patchVersion)"
        return "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let result = await MacInfoReader.read()
        guard !Task.isCancelled else { return }
        hardware = result
        identity = MacModelIdentity(modelIdentifier: result.modelIdentifier)
        image = identity.contentType.map { NSWorkspace.shared.icon(for: $0) }
            ?? NSImage(named: NSImage.computerName)
        refreshDisplays()
        loaded = true
    }

    func refreshDisplays() {
        displays = NSScreen.screens.flatMap { screen -> [String] in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return [screen.localizedName]
            }
            let display = CGDirectDisplayID(number.uint32Value)
            var name = screen.localizedName
            if CGDisplayIsBuiltin(display) != 0, let size = identity.size { name += " (\(size)″)" }
            guard let mode = CGDisplayCopyDisplayMode(display) else { return [name] }
            let rate = mode.refreshRate
            let refresh: String
            if rate > 0 {
                refresh = ", \(rate.formatted(.number.precision(.fractionLength(0...2)))) Hz"
            } else if screen.maximumFramesPerSecond > 0 {
                refresh = ", up to \(screen.maximumFramesPerSecond) Hz"
            } else { refresh = "" }
            return [name, "\(mode.pixelWidth) × \(mode.pixelHeight)\(refresh)"]
        }
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, seconds)) ?? "Unavailable"
    }
}
