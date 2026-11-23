import Testing
@testable import FanCore

private func battery(_ percent: Double?, temperature: Double? = 30) -> BatteryState {
    BatteryState(percent: percent, temperature: temperature, externalConnected: true)
}

@Test func chargeLimitHoldsThenSailsBeforeResuming() throws {
    var config = ChargeConfiguration(); config.enabled = true; config.limit = 80; config.sailing = 5
    var controller = try ChargeController(configuration: config)
    #expect(controller.next(battery(70)).allow)
    #expect(!controller.next(battery(80)).allow)
    #expect(!controller.next(battery(77)).allow) // Inside the sailing range.
    #expect(controller.next(battery(75)).allow)
    #expect(controller.next(battery(nil)).allow) // Missing readings never block charging.
}

@Test func heatProtectionPausesUntilBatteryCools() throws {
    var config = ChargeConfiguration(); config.heatProtection = true; config.heatLimit = 35
    var controller = try ChargeController(configuration: config)
    #expect(!controller.next(battery(50, temperature: 36)).allow)
    #expect(!controller.next(battery(50, temperature: 34)).allow)
    #expect(controller.next(battery(50, temperature: 33)).allow)
    config.heatLimit = 60
    #expect(throws: FanError.self) { try ChargeController(configuration: config) }
}
