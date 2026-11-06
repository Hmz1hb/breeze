import AppKit
import FanCore
import Observation

@MainActor @Observable
final class ActivityModel {
    enum Tab: String, CaseIterable { case cpu = "CPU", gpu = "GPU", memory = "Memory", processes = "Processes", thermal = "Thermal" }
    var tab = Tab.cpu
    var paused = false
    var windowSeconds = 120
    var latest: ActivityReading?
    var history: [ActivityReading] = []
    var processes: [ActivityProcess] = []
    var processError: String?
    var processUpdated: Date?
    let cpuName = ActivityHardware.string("machdep.cpu.brand_string") ?? "Mac processor"
    let logicalCores = ProcessInfo.processInfo.processorCount
    let physicalCores = ActivityHardware.integer("hw.physicalcpu")
    private let reader = ActivityReader()

    var samples: [ActivityReading] {
        guard let date = latest?.date else { return [] }
        return history.filter { $0.date.timeIntervalSince(date) >= -Double(windowSeconds) }
    }

    func run(when shouldRead: @MainActor () -> Bool = { true },
             includeProcesses: @MainActor () -> Bool = { false }) async {
        var needsBaseline = true
        while !Task.isCancelled {
            let readingEnabled = shouldRead()
            if !paused && readingEnabled {
                if needsBaseline { await reader.reset(); needsBaseline = false }
                let readsProcesses = tab == .processes || includeProcesses()
                let reading = await reader.read(includeProcesses: readsProcesses)
                guard !Task.isCancelled else { return }
                latest = reading
                history.append(reading)
                history.removeAll { $0.date < reading.date.addingTimeInterval(-600) }
                if let rows = reading.processes {
                    processes = rows; processUpdated = reading.date; processError = nil
                } else if readsProcesses { processError = reading.processError }
            } else {
                needsBaseline = true
                if !readingEnabled { latest = nil; processes = []; processUpdated = nil }
            }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
        }
    }
}

extension ActivityProcess {
    var cpuSort: Double { cpu ?? -1 }
    var memorySort: UInt64 { memory ?? 0 }
    var threadsSort: Int { threads ?? -1 }
    var timeSort: Double { cpuTime ?? -1 }
}
