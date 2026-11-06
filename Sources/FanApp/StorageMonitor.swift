import Foundation
import Observation
import StorageCore

@MainActor @Observable
final class StorageMonitor {
    var drives: [StorageDrive] = []
    var selectedID: String = "/"
    var loading = true
    var updated: Date?
    var history: [String: [DriveActivity]] = [:]
    var counters: [String: DriveCounters] = [:]
    var windowSeconds = 120
    var selected: StorageDrive? { drives.first { $0.id == selectedID } }
    // A logical volume can span several physical stores. Do not assign one
    // store's activity or SMART readings to a multi-device volume.
    var activityDevice: String? {
        guard let selected, selected.physicalDevices.count == 1 else { return nil }
        return selected.physicalDevices.first
    }
    var samples: [DriveActivity] {
        guard let activityDevice else { return [] }
        let now = Date.now
        return (history[activityDevice] ?? []).filter { $0.date.timeIntervalSince(now) >= -Double(windowSeconds) }
    }
    var latest: DriveActivity? { samples.last }
    var totals: DriveCounters? { activityDevice.flatMap { counters[$0] } }

    func run(when shouldRead: @MainActor () -> Bool = { true }) async {
        history = [:]
        var previous: [String: DriveCounters] = [:]
        var lastTime: TimeInterval?
        var nextMetadata = Date.distantPast
        while !Task.isCancelled {
            guard shouldRead() else {
                previous = [:]
                lastTime = nil
                nextMetadata = .distantPast
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                continue
            }
            if nextMetadata.timeIntervalSinceNow <= 0 {
                let volumes = await StorageDriveReader.volumes()
                guard !Task.isCancelled else { return }
                drives = volumes
                if !drives.contains(where: { $0.id == selectedID }) { selectedID = drives.first?.id ?? "/" }
                updated = .now
                loading = false
                nextMetadata = Date.now.addingTimeInterval(30)
            }
            let current = await StorageDriveReader.counters()
            guard !Task.isCancelled else { return }
            let time = ProcessInfo.processInfo.systemUptime
            let date = Date.now
            for (device, values) in current {
                if let old = previous[device], let lastTime {
                    if let sample = DriveActivity.sample(previous: old, current: values, elapsed: time - lastTime, date: date) {
                        history[device, default: []].append(sample)
                    } else {
                        history[device] = []
                    }
                }
            }
            let active = Set(drives.flatMap(\.physicalDevices))
            history = history.filter { active.contains($0.key) && current[$0.key] != nil }
                .mapValues { Array($0.filter { $0.date.timeIntervalSince(date) >= -120 }.suffix(61)) }
            counters = current
            previous = current
            lastTime = time
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}
