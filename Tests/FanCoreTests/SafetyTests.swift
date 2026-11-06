import Foundation
import Testing
@testable import FanCore

@Test func rpmEncodingMatchesHardwareFormats() throws {
    #expect(try SMCCodec.encode(2400, type: "fpe2", size: 2) == [0x25, 0x80])
    #expect(SMCCodec.decode([0x25, 0x80], type: "fpe2") == 2400)
    #expect(try SMCCodec.encode(2400, type: "flt ", size: 4) == [0, 0, 0x16, 0x45])
    #expect(SMCCodec.decode([0, 0, 0x16, 0x45], type: "flt ") == 2400)
    #expect(SMCCodec.decode([0xFF, 0x80], type: "sp78") == -0.5)
}

@Test func malformedOrUnsupportedEncodingFailsClosed() {
    #expect(SMCCodec.decode([0], type: "flt ") == nil)
    #expect(SMCCodec.decode([0, 0, 0xC0, 0x7F], type: "flt ") == nil)
    #expect(throws: FanError.self) { try SMCCodec.encode(.nan, type: "flt ", size: 4) }
    #expect(throws: FanError.self) { try SMCCodec.encode(-1, type: "fpe2", size: 2) }
    #expect(throws: FanError.self) { try SMCCodec.encode(20000, type: "fpe2", size: 2) }
    #expect(throws: FanError.self) { try SMCCodec.encode(1, type: "unknown", size: 4) }
}

@Test func targetsStayInsideBoundsAndNeverStopFans() throws {
    #expect(try Safety.target(percent: 0, minimum: 0, maximum: 6000) == 1200)
    #expect(try Safety.target(percent: 0, minimum: 1800, maximum: 6000) == 1800)
    #expect(try Safety.target(percent: 50, minimum: 1800, maximum: 6000) == 3900)
    #expect(try Safety.target(percent: 100, minimum: 1800, maximum: 6000) == 6000)
    #expect(throws: FanError.self) { try Safety.target(percent: .infinity, minimum: 0, maximum: 6000) }
    #expect(throws: FanError.self) { try Safety.target(percent: 101, minimum: 0, maximum: 6000) }
    #expect(throws: FanError.self) { try Safety.target(percent: 50, minimum: 6000, maximum: 1000) }
}

private func state(temperature: Double? = 45, pressure: String = "nominal", fans: Bool = true) -> Snapshot {
    Snapshot(fans: fans ? [Fan(id: 0, current: 1800, minimum: 1800, maximum: 6000, target: 1800, mode: 0)] : [],
             temperatures: temperature.map { [Temperature(key: "Tp01", celsius: $0)] } ?? [], thermalPressure: pressure)
}

@Test func hardwareGuardDoesNotReleaseControlBecauseOfHeat() throws {
    try Safety.check(state())
    try Safety.check(state(temperature: nil))
    try Safety.check(state(temperature: 100))
    try Safety.check(state(pressure: "serious"))
    try Safety.check(state(pressure: "critical"))
    #expect(throws: FanError.self) { try Safety.check(state(fans: false)) }
}

@Test func watchdogHandlesStaleHeartbeatAndClockDiscontinuity() {
    #expect(!Safety.expired(last: 100, now: 105))
    #expect(Safety.expired(last: 100, now: 107))
    #expect(Safety.expired(last: 100, now: 90))
}

@Test func firmwareAcknowledgementIsNotTreatedAsSuccessfulActivation() throws {
    var attempts = 0
    var pauses = 0
    try WriteVerification.apply(attempts: 5, write: { attempts += 1 },
                                matches: { attempts >= 3 }, pause: { pauses += 1 })
    #expect(attempts == 3)
    #expect(pauses == 3)
}

@Test func rejectedFirmwareWritesStopAtTheRetryLimit() {
    var attempts = 0
    #expect(throws: FanError.self) {
        try WriteVerification.apply(attempts: 5, write: { attempts += 1 }, matches: { false }, pause: {})
    }
    #expect(attempts == 5)
}

@Test func temporaryWriteFailuresCanRecover() throws {
    var attempts = 0
    try WriteVerification.apply(attempts: 5, write: {
        attempts += 1
        if attempts < 2 { throw FanError("Busy") }
    }, matches: { attempts >= 2 }, pause: {})
    #expect(attempts == 2)
}
