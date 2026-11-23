import Foundation

public enum CoolingMode: String, CaseIterable, Codable, Sendable {
    case automatic, manual, curve, target
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .manual: "Fixed speed"
        case .curve: "Custom curve"
        case .target: "Target temperature"
        }
    }
}

public struct CurvePoint: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var temperature: Double
    public var percent: Double
    public init(temperature: Double, percent: Double) {
        id = UUID(); self.temperature = temperature; self.percent = percent
    }
}

/// Which die readings drive curve and target modes. Heat boost always uses the hottest die.
public enum CoolingSensor: String, Codable, CaseIterable, Sendable {
    case hottest, cpu, gpu

    public var title: String {
        switch self { case .hottest: "Hottest die"; case .cpu: "CPU dies"; case .gpu: "GPU dies" }
    }

    public func temperature(in snapshot: Snapshot) -> Double? {
        switch self {
        case .hottest: snapshot.hottest
        case .cpu: snapshot.cpuTemperature ?? snapshot.hottest
        case .gpu: snapshot.gpuTemperature ?? snapshot.hottest
        }
    }
}

public struct CoolingConfiguration: Codable, Equatable, Sendable {
    public var mode: CoolingMode = .manual
    /// Optional so profiles saved before sensor selection still decode; nil means hottest die.
    public var sensor: CoolingSensor?
    public var manualPercent: Double = 100
    public var targetTemperature: Double = 75
    public var boostTemperature: Double = 90
    public var points: [CurvePoint] = [
        CurvePoint(temperature: 35, percent: 20), CurvePoint(temperature: 55, percent: 40),
        CurvePoint(temperature: 65, percent: 65), CurvePoint(temperature: 75, percent: 90),
        CurvePoint(temperature: 85, percent: 100)
    ]
    public init() {}

    public func validate() throws {
        guard manualPercent.isFinite, (0...100).contains(manualPercent),
              targetTemperature.isFinite, (40...90).contains(targetTemperature),
              boostTemperature.isFinite, (75...100).contains(boostTemperature) else {
            throw FanError("Choose valid speeds and temperatures (target 40–90°C, full-speed boost 75–100°C).")
        }
        guard mode != .curve || (2...12).contains(points.count) else { throw FanError("A curve needs 2–12 points.") }
        if mode == .curve {
            for (i, point) in points.enumerated() {
                guard point.temperature.isFinite, (20...110).contains(point.temperature),
                      point.percent.isFinite, (0...100).contains(point.percent) else {
                    throw FanError("Curve temperatures must be 20–110°C and speeds 0–100%.")
                }
                if i > 0 {
                    guard point.temperature > points[i-1].temperature, point.percent >= points[i-1].percent else {
                        throw FanError("Curve temperatures must increase, and fan speeds must not decrease as it gets hotter.")
                    }
                }
            }
        }
    }
    public func curvePercent(at temperature: Double) throws -> Double {
        try validate()
        guard temperature.isFinite, let first = points.first, let last = points.last else { throw FanError("Invalid curve input.") }
        if temperature <= first.temperature { return first.percent }
        if temperature >= last.temperature { return last.percent }
        for (lower, upper) in zip(points, points.dropFirst()) where temperature <= upper.temperature {
            let fraction = (temperature-lower.temperature)/(upper.temperature-lower.temperature)
            return lower.percent + fraction*(upper.percent-lower.percent)
        }
        return last.percent
    }
}

public struct CoolingDecision: Sendable {
    public let percent: Double
    public let boosted: Bool
    public let message: String
}

/// Pure controller: no hardware writes. The privileged helper owns one instance per session.
public struct CoolingController: Sendable {
    public private(set) var configuration: CoolingConfiguration
    private var previousPercent: Double?
    private var previousTemperature: Double?
    private var previousTime: Double?
    private var integral = 0.0
    private var boostLatched = false

    public init(configuration: CoolingConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
    }
    public mutating func next(snapshot: Snapshot, now: Double) throws -> CoolingDecision {
        guard configuration.mode != .automatic else { throw FanError("Automatic cooling does not use a custom controller.") }
        try Safety.check(snapshot)
        guard now.isFinite else { throw FanError("Invalid controller clock.") }
        let elapsed = previousTime.map { max(0, min(5, now-$0)) } ?? 1
        previousTime = now
        let temperature = snapshot.hottest
        let pressure = ["serious", "critical"].contains(snapshot.thermalPressure)
        if temperature == nil || pressure || (temperature ?? 0) >= configuration.boostTemperature { boostLatched = true }
        else if let temperature, temperature <= configuration.boostTemperature-3 { boostLatched = false }

        // Curves and targets may follow a chosen group; it falls back to the hottest die when
        // that group has no readings. Boost and sensor loss above stay on the hottest die.
        let source = configuration.sensor ?? .hottest
        let control = temperature == nil ? nil : source.temperature(in: snapshot)
        let demand: Double
        var message: String
        if boostLatched {
            demand = 100
            message = temperature == nil ? "Sensor unavailable: holding maximum cooling." : "Heat boost: maximum cooling stays active until the Mac cools by 3°C."
        } else {
            switch configuration.mode {
            case .automatic: throw FanError("Automatic cooling does not use a custom controller.")
            case .manual:
                demand = configuration.manualPercent
                message = demand == 100 ? "Maximum cooling is active." : "Fixed fan speed is active."
            case .curve:
                demand = try configuration.curvePercent(at: control ?? 100)
                message = "Custom curve is following the \(source.title.lowercased())."
            case .target:
                let current = control ?? 100
                let error = current - configuration.targetTemperature
                integral = max(-30, min(50, integral + error*elapsed*0.15))
                let rising = previousTemperature.map { max(0, (current-$0)/max(0.25, elapsed)) } ?? 0
                demand = max(0, min(100, 50 + error*6 + integral + rising*6))
                message = "Adjusting fans toward \(Int(configuration.targetTemperature))°C."
            }
        }
        previousTemperature = control
        var output = demand
        // Respond immediately to rising demand. Slow reductions avoid fan hunting.
        if let previousPercent, demand < previousPercent {
            output = max(demand, previousPercent-elapsed*2)
        }
        previousPercent = output
        if configuration.mode == .target, output >= 99,
           let control, control > configuration.targetTemperature {
            message = "Maximum cooling. The workload is still above the temperature target."
        }
        return CoolingDecision(percent: output.rounded(), boosted: boostLatched, message: message)
    }
}
