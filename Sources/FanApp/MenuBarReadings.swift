import Foundation
import IOKit.ps
import NetworkCore
import Observation

struct MenuBarBattery: Equatable {
    let percent: Int
    let charging: Bool
}

/// Interface rate and battery level for the menu bar. Each reading is sampled only
/// while it is shown there; the Network and Battery pages keep their own samplers.
@MainActor @Observable final class MenuBarReadings {
    private(set) var traffic: NetworkTraffic?
    private(set) var battery: MenuBarBattery?

    func run(network: @MainActor () -> Bool, battery readsBattery: @MainActor () -> Bool) async {
        var interface: String?
        var previous: NetworkCounters?
        var lastTime: TimeInterval?
        var nextInterface = Date.distantPast
        var nextBattery = Date.distantPast
        while !Task.isCancelled {
            if network() {
                if nextInterface <= .now {
                    let connection = await NetworkReader.connection()
                    let current = connection.isUp ? connection.interface : nil
                    // Counters of a different interface are not comparable.
                    if current != interface { previous = nil; traffic = nil }
                    interface = current
                    nextInterface = .now.addingTimeInterval(5)
                }
                let current = if let interface { await NetworkReader.counters(interface: interface) } else { NetworkCounters?.none }
                let time = ProcessInfo.processInfo.systemUptime
                if let previous, let current, let lastTime, time - lastTime < 10,
                   let sample = NetworkTraffic.sample(previous: previous, current: current, elapsed: time - lastTime) {
                    traffic = sample
                } else if current == nil { traffic = nil }
                previous = current; lastTime = time
            } else {
                interface = nil; previous = nil; traffic = nil; nextInterface = .distantPast
            }
            if readsBattery() {
                if nextBattery <= .now { battery = Self.readBattery(); nextBattery = .now.addingTimeInterval(10) }
            } else {
                battery = nil; nextBattery = .distantPast
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    /// Power Sources summary only: far cheaper than the Battery page's full registry read.
    static func readBattery() -> MenuBarBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return MenuBarBattery(percent: min(100, max(0, current * 100 / maximum)),
                                  charging: description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    /// Compact rate for the menu bar, at most three significant digits: "820 KB/s", "4.2 MB/s".
    nonisolated static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = max(0, bytesPerSecond), unit = 0
        while value >= 999.5, unit < units.count - 1 { value /= 1000; unit += 1 }
        return String(format: unit > 0 && value < 9.95 ? "%.1f %@/s" : "%.0f %@/s", value, units[unit])
    }
}
