import Foundation
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

@Test func topUpChargesPastTheLimitUntilUnplugged() throws {
    var config = ChargeConfiguration(); config.enabled = true; config.limit = 80; config.topUp = true
    var controller = try ChargeController(configuration: config)
    #expect(controller.next(battery(90)).allow)
    #expect(controller.isToppingUp)
    // Unplugging ends the top up for good; the limit applies again.
    _ = controller.next(BatteryState(percent: 95, temperature: 30, externalConnected: false))
    #expect(!controller.isToppingUp)
    #expect(!controller.next(battery(95)).allow)
}

@Test func dischargeDisconnectsTheAdapterAboveTheLimitOnly() throws {
    var config = ChargeConfiguration(); config.enabled = true; config.limit = 80; config.discharge = true
    var controller = try ChargeController(configuration: config)
    #expect(controller.next(battery(80.5)).adapter) // Within one point: no toggling at the limit.
    #expect(!controller.next(battery(85)).adapter)
    #expect(!controller.next(battery(81)).adapter)
    #expect(controller.next(battery(80)).adapter)
    #expect(controller.next(battery(nil)).adapter) // Missing readings always reconnect.
    _ = controller.next(battery(90))
    controller.stopDischarge()
    #expect(controller.next(battery(90)).adapter)
}

@Test func topUpAndDischargeAreExclusiveAndOldSettingsDecode() throws {
    var config = ChargeConfiguration(); config.topUp = true; config.discharge = true
    #expect(throws: FanError.self) { try config.validate() }
    let legacy = Data(#"{"enabled":true,"limit":80,"sailing":5,"heatProtection":false,"heatLimit":35}"#.utf8)
    let decoded = try JSONDecoder().decode(ChargeConfiguration.self, from: legacy)
    #expect(decoded.enabled && decoded.discharge == nil && decoded.topUp == nil && decoded.pauseDuringSleep == nil)
}

@Test func pauseCheckFlagsOnlyChargingThatOutlastsTheGracePeriod() {
    var check = PauseCheck()
    let grace = PauseCheck.grace
    // Restarts on a non-charging or unreadable reading; flags only a full grace period of charging.
    let readings: [(Bool?, Double)] = [(true, 0), (true, grace - 1), (false, grace), (true, 100),
                                       (nil, 110), (true, 120), (true, 120 + grace)]
    let flags = readings.map { check.ineffective(paused: true, charging: $0.0, now: $0.1) }
    #expect(flags == [false, false, false, false, false, false, true])
    // Charging while not paused is expected.
    var idle = PauseCheck()
    let idleFlags = [0.0, 1000].map { idle.ineffective(paused: false, charging: true, now: $0) }
    #expect(idleFlags == [false, false])
}
