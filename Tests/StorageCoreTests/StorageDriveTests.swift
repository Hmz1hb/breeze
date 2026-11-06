import Foundation
import Testing
@testable import StorageCore

@Test func nvmeHealthUsesKelvinAnd512ThousandByteUnits() throws {
    let health = DriveHealth(info: ["SMARTStatus": "Verified", "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
        "TEMPERATURE": 303, "PERCENTAGE_USED": 4, "DATA_UNITS_READ_0": 246_716_668,
        "DATA_UNITS_READ_1": 0, "DATA_UNITS_WRITTEN_0": 221_581_406,
        "POWER_ON_HOURS_0": 3935, "POWER_CYCLES_0": 417, "UNSAFE_SHUTDOWNS_0": 49,
        "MEDIA_ERRORS_0": 0, "AVAILABLE_SPARE": 100]])
    #expect(health.status == "Verified")
    #expect(abs(try #require(health.temperature) - 29.85) < 0.001)
    #expect(health.lifeRemaining == 96)
    #expect(health.lifetimeRead == 126_318_934_016_000)
    #expect(health.lifetimeWritten == 113_449_679_872_000)
    #expect(health.powerOnHours == 3935)
    #expect(health.powerCycles == 417)
    #expect(health.unsafeShutdowns == 49)
    #expect(health.mediaErrors == 0)
    #expect(health.availableSpare == 100)
    #expect(health.criticalWarning == nil)
}

@Test func unavailableHealthDoesNotImplyHealthyOrZeroCounters() {
    let health = DriveHealth(info: [:])
    #expect(health.status == nil)
    #expect(health.temperature == nil)
    #expect(health.lifeRemaining == nil)
    #expect(health.mediaErrors == nil)
    #expect(health.lifetimeRead == nil)
    #expect(health.powerOnHours == nil)
    let worn = DriveHealth(info: ["SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
        "PERCENTAGE_USED": 137, "TEMPERATURE": 0, "DATA_UNITS_READ_0": 1, "DATA_UNITS_READ_1": 1]])
    #expect(worn.lifeRemaining == 0)
    #expect(worn.temperature == nil)
    #expect(worn.lifetimeRead == nil) // A value beyond Int64 must not trap or wrap.
}

@Test func activityUsesElapsedTimeAndRejectsResetAndWakeGaps() throws {
    let old = DriveCounters(read: 1000, written: 2000, readOperations: 10, writeOperations: 20)
    let new = DriveCounters(read: 7000, written: 4000, readOperations: 20, writeOperations: 24)
    let sample = try #require(DriveActivity.sample(previous: old, current: new, elapsed: 2))
    #expect(sample.readRate == 3000)
    #expect(sample.writeRate == 1000)
    #expect(sample.readIOPS == 5)
    #expect(sample.writeIOPS == 2)
    #expect(DriveActivity.sample(previous: new, current: old, elapsed: 2) == nil)
    #expect(DriveActivity.sample(previous: old, current: new, elapsed: 0) == nil)
    #expect(DriveActivity.sample(previous: old, current: new, elapsed: 60) == nil)
}

@Test(arguments: [("disk0s2", "disk0"), ("disk12s3", "disk12"), ("disk4", "disk4")])
func apfsPhysicalStoresResolveToTheirWholeDevice(_ input: String, _ expected: String) {
    #expect(StorageDriveReader.wholeDisk(input) == expected)
}
