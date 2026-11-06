import Foundation

enum WidgetMetric: String, Codable, CaseIterable, Identifiable {
    case temperature, fans, cpu, gpu, memory, storage
    var id: Self { self }
    var title: String {
        switch self {
        case .temperature: "Temperature"
        case .fans: "Fan speed"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .storage: "Storage"
        }
    }
    var symbol: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .fans: "fanblades"
        case .cpu: "cpu"
        case .gpu: "square.3.layers.3d"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        }
    }
}

enum WidgetSection: String, Codable, CaseIterable, Identifiable {
    case history, fans, cpu, memory, storage, sensors, processes, controls
    var id: Self { self }
    var title: String {
        switch self {
        case .history: "Temperature history"
        case .fans: "Individual fans"
        case .cpu: "CPU details & core activity"
        case .memory: "Memory breakdown & swap"
        case .storage: "Storage capacity & disk activity"
        case .sensors: "Thermal pressure & die sensors"
        case .processes: "Top processes"
        case .controls: "Cooling controls"
        }
    }
}

struct WidgetPreferences: Codable, Equatable {
    var metrics: Set<WidgetMetric> = [.temperature, .fans]
    var menuMetrics: Set<WidgetMetric> = [.temperature]
    var sections: Set<WidgetSection> = [.history, .controls]
    var historySeconds = 300

    static let simple = WidgetPreferences()
    static let detailed = WidgetPreferences(
        metrics: Set(WidgetMetric.allCases),
        menuMetrics: [.temperature, .cpu, .memory],
        sections: Set(WidgetSection.allCases))

    var presetName: String {
        if self == .simple { return "Simple" }
        if self == .detailed { return "Detailed" }
        return "Custom"
    }
    var needsActivityInPopover: Bool {
        metrics.contains(.gpu) || !sections.isDisjoint(with: [.cpu, .memory, .processes])
    }
    var needsActivityInMenuBar: Bool { menuMetrics.contains(.gpu) }
    var needsStorageInPopover: Bool { metrics.contains(.storage) || sections.contains(.storage) }
    var needsStorageInMenuBar: Bool { menuMetrics.contains(.storage) }

    static func load(from data: Data?) -> Self {
        guard let data, var value = try? JSONDecoder().decode(Self.self, from: data) else { return .simple }
        if ![120, 300, 600].contains(value.historySeconds) { value.historySeconds = 300 }
        return value
    }
}
