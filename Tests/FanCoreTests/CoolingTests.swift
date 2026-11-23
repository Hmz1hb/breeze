import Foundation
import Testing
@testable import FanCore

private func reading(_ temperature: Double?, pressure: String = "nominal") -> Snapshot {
    Snapshot(fans: [Fan(id: 0, current: 2500, minimum: 1499, maximum: 5348, target: 2500, mode: 1)],
             temperatures: temperature.map { [Temperature(key: "Tp01", celsius: $0)] } ?? [], thermalPressure: pressure)
}

@Test(arguments: [76.0, 80, 89, 90, 100, 110])
func maximumCoolingIsRetainedAtHighTemperatures(_ temperature: Double) throws {
    let profile = CoolingConfiguration()
    var controller = try CoolingController(configuration: profile)
    let result = try controller.next(snapshot: reading(temperature), now: 0)
    #expect(result.percent == 100)
}

@Test(arguments: ["serious", "critical"])
func pressureIncreasesCoolingInsteadOfReleasingControl(_ pressure: String) throws {
    var profile = CoolingConfiguration(); profile.manualPercent = 30
    var controller = try CoolingController(configuration: profile)
    let result = try controller.next(snapshot: reading(70, pressure: pressure), now: 0)
    #expect(result.percent == 100)
    #expect(result.boosted)
}

@Test func missingTemperatureUsesMaximumCooling() throws {
    var profile = CoolingConfiguration(); profile.manualPercent = 30
    var controller = try CoolingController(configuration: profile)
    let result = try controller.next(snapshot: reading(nil), now: 0)
    #expect(result.percent == 100)
    #expect(result.message.contains("Sensor unavailable"))
}

@Test func customCurvesInterpolateAndClampEndpoints() throws {
    var profile = CoolingConfiguration(); profile.mode = .curve
    profile.points = [CurvePoint(temperature: 40, percent: 20), CurvePoint(temperature: 80, percent: 100)]
    #expect(try profile.curvePercent(at: 10) == 20)
    #expect(try profile.curvePercent(at: 60) == 60)
    #expect(try profile.curvePercent(at: 100) == 100)
}

@Test func invalidCurvesDoNotReachHardware() {
    var profile = CoolingConfiguration(); profile.mode = .curve
    profile.points = [CurvePoint(temperature: 70, percent: 80), CurvePoint(temperature: 50, percent: 100)]
    #expect(throws: FanError.self) { try profile.validate() }
    profile.points = [CurvePoint(temperature: 50, percent: 80), CurvePoint(temperature: 70, percent: 40)]
    #expect(throws: FanError.self) { try profile.validate() }
    profile.points = [CurvePoint(temperature: .nan, percent: 20), CurvePoint(temperature: 70, percent: 100)]
    #expect(throws: FanError.self) { try profile.validate() }
    profile.points = [CurvePoint(temperature: 50, percent: 110), CurvePoint(temperature: 70, percent: 100)]
    #expect(throws: FanError.self) { try profile.validate() }
}

@Test func boostHasHysteresisAndCoolingEasesSlowly() throws {
    var profile = CoolingConfiguration(); profile.manualPercent = 30
    var controller = try CoolingController(configuration: profile)
    #expect(try controller.next(snapshot: reading(90), now: 0).percent == 100)
    let hovering = try controller.next(snapshot: reading(88), now: 1)
    #expect(hovering.boosted && hovering.percent == 100)
    let cooled = try controller.next(snapshot: reading(86), now: 2)
    #expect(!cooled.boosted && cooled.percent == 98)
}

@Test func curveRespondsImmediatelyToIncreasingHeat() throws {
    var profile = CoolingConfiguration(); profile.mode = .curve
    profile.points = [CurvePoint(temperature: 40, percent: 20), CurvePoint(temperature: 80, percent: 100)]
    var controller = try CoolingController(configuration: profile)
    #expect(try controller.next(snapshot: reading(40), now: 0).percent == 20)
    #expect(try controller.next(snapshot: reading(80), now: 1).percent == 100)
}

@Test func targetControllerRespondsToTemperatureAndRisingLoad() throws {
    var profile = CoolingConfiguration(); profile.mode = .target; profile.targetTemperature = 75
    var controller = try CoolingController(configuration: profile)
    let low = try controller.next(snapshot: reading(65), now: 0)
    let rising = try controller.next(snapshot: reading(78), now: 1)
    #expect(rising.percent > low.percent)
    #expect(rising.percent == 100)
    #expect(rising.message.contains("workload"))
}

@Test func savedProfileAndWakeCommandsRoundTrip() throws {
    var profile = CoolingConfiguration(); profile.mode = .curve
    profile.points[0].percent = 35
    let data = try JSONEncoder().encode(Command(.configure, configuration: profile))
    let command = try JSONDecoder().decode(Command.self, from: data)
    #expect(command.configuration == profile)
    for action in [Command.Action.sleep, .wake] {
        let encoded = try JSONEncoder().encode(Command(action))
        #expect(try JSONDecoder().decode(Command.self, from: encoded).action == action)
    }
}

@Test func systemStatisticsAreReadableWithoutElevatedPrivileges() throws {
    var reader = SystemStatsReader()
    let result = try reader.read()
    #expect(result.memoryTotal > 0)
    #expect(result.memoryUsed <= result.memoryTotal)
    #expect(result.uptime > 0)
}

private func dies(cpu: Double, gpu: Double?) -> Snapshot {
    Snapshot(fans: [Fan(id: 0, current: 2500, minimum: 1499, maximum: 5348, target: 2500, mode: 1)],
             temperatures: [Temperature(key: "Tp01", celsius: cpu)] + (gpu.map { [Temperature(key: "Tg05", celsius: $0)] } ?? []),
             thermalPressure: "nominal")
}

@Test func curveFollowsTheChosenSensorGroupWhileBoostWatchesTheHottestDie() throws {
    var profile = CoolingConfiguration(); profile.mode = .curve; profile.sensor = .gpu
    var controller = try CoolingController(configuration: profile)
    // GPU at 35°C maps to the curve's first point even though the CPU is warmer.
    let cool = try controller.next(snapshot: dies(cpu: 70, gpu: 35), now: 0)
    #expect(cool.percent == profile.points[0].percent)
    #expect(!cool.boosted)
    // A CPU die over the boost threshold still forces maximum cooling.
    let hot = try controller.next(snapshot: dies(cpu: 95, gpu: 35), now: 1)
    #expect(hot.percent == 100)
    #expect(hot.boosted)
}

@Test func chosenSensorFallsBackToTheHottestDieWithoutReadings() throws {
    #expect(CoolingSensor.gpu.temperature(in: dies(cpu: 72, gpu: nil)) == 72)
    #expect(CoolingSensor.cpu.temperature(in: dies(cpu: 60, gpu: 80)) == 60)
    #expect(CoolingSensor.hottest.temperature(in: dies(cpu: 60, gpu: 80)) == 80)
}

@Test func profilesSavedBeforeSensorSelectionStillDecode() throws {
    let original = CoolingConfiguration()
    var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    legacy.removeValue(forKey: "sensor")
    let decoded = try JSONDecoder().decode(CoolingConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.sensor == nil)
    #expect(decoded.mode == original.mode && decoded.points.map(\.temperature) == original.points.map(\.temperature))
}
