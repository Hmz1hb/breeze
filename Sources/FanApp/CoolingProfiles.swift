import FanCore
import Foundation

enum CoolingPreset: String, CaseIterable, Identifiable {
    case quiet = "Quiet", balanced = "Balanced", performance = "Performance"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .quiet: "leaf"
        case .balanced: "scale.3d"
        case .performance: "bolt"
        }
    }
    var detail: String {
        switch self {
        case .quiet: "A gentler curve for lighter work."
        case .balanced: "Everyday cooling that grows with your workload."
        case .performance: "Earlier, stronger cooling for demanding work."
        }
    }
    func configuration(boostTemperature: Double) -> CoolingConfiguration {
        var result = CoolingConfiguration()
        result.mode = .curve
        result.boostTemperature = boostTemperature
        switch self {
        case .quiet:
            result.points = [CurvePoint(temperature: 40, percent: 0), CurvePoint(temperature: 60, percent: 20),
                             CurvePoint(temperature: 75, percent: 55), CurvePoint(temperature: 85, percent: 100)]
        case .balanced: break
        case .performance:
            result.points = [CurvePoint(temperature: 35, percent: 35), CurvePoint(temperature: 50, percent: 60),
                             CurvePoint(temperature: 60, percent: 85), CurvePoint(temperature: 70, percent: 100)]
        }
        return result
    }
}

struct SavedCoolingProfile: Codable, Identifiable {
    let id: UUID
    let name: String
    let configuration: CoolingConfiguration

    init(name: String, configuration: CoolingConfiguration) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { throw FanError("Give the profile a name of 1–40 characters.") }
        try configuration.validate()
        id = UUID()
        self.name = trimmed
        self.configuration = configuration
    }

    static func load(from data: Data?) -> [Self] {
        guard let data, let profiles = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        var seen = Set<UUID>()
        return profiles.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 &&
            (try? $0.configuration.validate()) != nil && seen.insert($0.id).inserted
        }
    }
}
