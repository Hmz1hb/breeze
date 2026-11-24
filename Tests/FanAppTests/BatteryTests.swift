import Foundation
import IOKit.ps
import Testing
@testable import FanApp

@Test func batteryIdleDoesNotMeanTheMacIsUsingZeroPower() {
    let reading = BatteryReading.parse(source: [
        kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: false
    ], registry: [
        "Amperage": 0, "Voltage": 12_036,
        "PowerTelemetryData": ["SystemPowerIn": 55_445, "SystemVoltageIn": 27_683, "SystemCurrentIn": 2_002]
    ], adapter: ["Watts": 140])
    #expect(reading.adapterInputWatts == 55.445)
    #expect(reading.adapterInputVoltage == 27.683)
    #expect(reading.adapterInputCurrent == 2.002)
    #expect(reading.batteryWatts == 0)
    #expect(reading.batteryFlowLabel == "Idle · 0.0 W")
    #expect(reading.adapter?.watts == 140)
}

@Test func batteryIgnoresStaleInputTelemetryWhenUnplugged() {
    let reading = BatteryReading.parse(source: [kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue], registry: [
        "Amperage": -1_500, "Voltage": 12_000,
        "PowerTelemetryData": ["SystemPowerIn": 55_445, "SystemVoltageIn": 27_683, "SystemCurrentIn": 2_002]
    ], adapter: nil)
    #expect(reading.adapterInputWatts == nil)
    #expect(reading.adapterInputVoltage == nil)
    #expect(reading.adapterInputCurrent == nil)
    #expect(reading.batteryFlowLabel.hasPrefix("Discharging"))
}

@Test(arguments: [NSNumber(value: -1), NSNumber(value: UInt64.max), NSNumber(value: Double.nan), NSNumber(value: true)])
func batteryRejectsInvalidInputPower(_ invalid: NSNumber) {
    let reading = BatteryReading.parse(source: [kIOPSPowerSourceStateKey: kIOPSACPowerValue], registry: [
        "PowerTelemetryData": ["SystemPowerIn": invalid]
    ], adapter: ["Watts": 140])
    #expect(reading.adapterInputWatts == nil)
}

@Test func batteryDoesNotUseChargerRatingAsLivePowerWhenTelemetryIsMissing() {
    let reading = BatteryReading.parse(source: [kIOPSPowerSourceStateKey: kIOPSACPowerValue], registry: nil,
                                       adapter: ["Watts": 140, "AdapterVoltage": 28_000, "Current": 4_990])
    #expect(reading.adapterInputWatts == nil)
    #expect(reading.batteryFlowLabel == "Unavailable")
}

@Test func batteryUsesMacOSReportedHealthBeforeCapacityEstimate() throws {
    let report = try BatteryHealthReport.parse(Data(#"""
    {"SPPowerDataType":[{"_name":"spbattery_information",
      "sppower_battery_health_info":{"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"84%"},
      "sppower_battery_model_info":{"sppower_battery_serial_number":"TEST-BATTERY","sppower_battery_device_name":"bq40z651","sppower_battery_firmware_version":"0b00"}}]}
    """#.utf8))
    var reading = BatteryReading.parse(source: [:], registry: [
        "DesignCapacity": 8_694, "NominalChargeCapacity": 7_372
    ], adapter: nil)
    report.apply(to: &reading)
    #expect(reading.healthPercent == 84)
    #expect(reading.reportedHealthPercent == 84)
    #expect(reading.condition == "Normal")
    #expect(reading.serialNumber == "TEST-BATTERY")
    #expect(reading.deviceName == "bq40z651")
    let missing = try BatteryHealthReport.parse(Data("{}".utf8))
    #expect(missing.condition == nil)
    #expect(missing.maximumCapacity == nil)
}

@Test func batterySeparatesChargePercentageFromCapacityAndChargerRating() throws {
    let reading = BatteryReading.parse(source: [
        kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100,
        kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: false,
        kIOPSIsChargedKey: false, kIOPSBatteryHealthKey: kIOPSGoodValue
    ], registry: [
        "MaxCapacity": 100, "CycleCount": 188, "Amperage": 0, "Voltage": 12_035,
        "BatteryData": ["DesignCapacity": 8_694, "NominalChargeCapacity": 7_372,
                        "AppleRawMaxCapacity": 7_128, "AppleRawCurrentCapacity": 5_545],
        "AdapterDetails": ["Name": "140W USB-C Power Adapter", "Manufacturer": "Apple Inc.",
                           "Watts": 140, "AdapterVoltage": 28_000, "Current": 4_990,
                           "SerialString": "TEST-ADAPTER"]
    ], adapter: ["Watts": 140])
    #expect(reading.percent == 80)
    #expect(reading.fullChargeCapacity == 7_128)
    #expect(reading.remainingCapacity == 5_545)
    #expect(abs(try #require(reading.healthPercent) - 84.7941) < 0.01)
    #expect(reading.condition == "Normal")
    #expect(reading.cycles == 188)
    #expect(reading.status == "Plugged in · Not charging")
    #expect(reading.timeLabel == "External power")
    #expect(reading.adapter?.watts == 140)
    #expect(reading.adapter?.voltage == 28)
    #expect(reading.adapter?.current == 4.99)
    #expect(reading.adapter?.name == "140W USB-C Power Adapter")
    #expect(reading.batteryWatts == 0)
}

@Test(arguments: [NSNumber(value: -1_500), NSNumber(value: UInt64.max - 1_499), NSNumber(value: UInt32.max - 1_499)])
func batteryDecodesSignedDischargeCurrent(_ current: NSNumber) {
    let reading = BatteryReading.parse(source: [
        kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsChargingKey: false,
        kIOPSTimeToEmptyKey: 125, kIOPSTimeToFullChargeKey: 30
    ], registry: ["Voltage": 12_000, "Amperage": current, "Temperature": 3_050],
       adapter: ["Watts": 140])
    #expect(reading.amperage == -1_500)
    #expect(reading.batteryWatts == -18)
    #expect(reading.temperature == 30.5)
    #expect(reading.adapter == nil)
    #expect(reading.status == "On battery")
    #expect(reading.timeLabel == "2 hr 5 min")
    #expect(reading.minutesToFull == nil)
}

@Test func batteryOnlyUsesTimeEstimateForCurrentPowerState() {
    let charging = BatteryReading.parse(source: [
        kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: true,
        kIOPSTimeToFullChargeKey: 45, kIOPSTimeToEmptyKey: 200
    ], registry: nil, adapter: nil)
    #expect(charging.status == "Charging")
    #expect(charging.timeLabel == "45 min")
    #expect(charging.minutesToEmpty == nil)
    let full = BatteryReading.parse(source: [kIOPSIsChargedKey: true], registry: nil, adapter: nil)
    #expect(full.status == "Fully charged")
    #expect(full.timeLabel == "Fully charged")
}

@Test func batteryCanDischargeWhileAnAdapterIsConnected() {
    let reading = BatteryReading.parse(source: [
        kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsChargingKey: false,
        kIOPSTimeToEmptyKey: 70
    ], registry: ["ExternalConnected": true], adapter: ["Watts": 20])
    #expect(reading.externalConnected == true)
    #expect(reading.runningOnBattery == true)
    #expect(reading.status == "Plugged in · Discharging")
    #expect(reading.adapter?.watts == 20)
    #expect(reading.timeLabel == "1 hr 10 min")
}

@Test(arguments: [-1, 0, 65_535, Int.max])
func batteryRejectsUnknownTimeEstimates(_ minutes: Int) {
    let reading = BatteryReading.parse(source: [
        kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
        kIOPSIsChargingKey: false, kIOPSTimeToEmptyKey: minutes
    ], registry: nil, adapter: nil)
    #expect(reading.minutesToEmpty == nil)
    #expect(reading.timeLabel == "Estimating…")
}

@Test func batteryHandlesIntelCapacityAndIncompleteReadings() {
    let intel = BatteryReading.parse(source: nil, registry: [
        "BatteryInstalled": true, "CurrentCapacity": 3_000, "MaxCapacity": 5_000,
        "DesignCapacity": 6_000, "CycleCount": 0, "IsCharging": true,
        "ExternalConnected": true, "Amperage": 1_000, "Voltage": 12_000
    ], adapter: nil)
    #expect(intel.percent == 60)
    #expect(intel.fullChargeCapacity == 5_000)
    #expect(intel.remainingCapacity == 3_000)
    #expect(intel.cycles == 0)
    #expect(intel.batteryWatts == 12)
    let missing = BatteryReading.parse(source: [:], registry: ["MaxCapacity": 100], adapter: nil)
    #expect(missing.availability == .available)
    #expect(missing.fullChargeCapacity == nil)
    #expect(missing.healthPercent == nil)
    #expect(missing.percent == nil)
    #expect(missing.charging == nil)
    #expect(missing.condition == nil)
    #expect(missing.status == "Status unavailable")
    #expect(BatteryReading.parse(source: nil, registry: nil, adapter: nil).availability == .noBattery)
    #expect(BatteryReading.parse(source: nil, registry: nil, adapter: nil, sourcesReadable: false).availability == .unavailable)
}

@Test func batteryRejectsInvalidCapacityAndRetainsReportedServiceCondition() {
    let reading = BatteryReading.parse(source: [
        kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 0,
        kIOPSBatteryHealthConditionKey: kIOPSCheckBatteryValue
    ], registry: ["DesignCapacity": 0, "AppleRawMaxCapacity": -1, "CycleCount": -1,
                  "Temperature": 65_535, "Voltage": 0], adapter: nil)
    #expect(reading.percent == nil)
    #expect(reading.healthPercent == nil)
    #expect(reading.cycles == nil)
    #expect(reading.temperature == nil)
    #expect(reading.voltage == nil)
    #expect(reading.condition == "Check Battery")
}

@Test func batteryTemperatureFallsBackToBatteryData() {
    let reading = BatteryReading.parse(source: nil, registry: ["BatteryData": ["Temperature": 3_029]], adapter: nil)
    #expect(reading.temperature == 30.29)
}
