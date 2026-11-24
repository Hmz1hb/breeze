import FanCore
import Foundation
import Testing
@testable import FanApp

@Test func bluetoothBatteriesParseConnectedDevicesOnly() throws {
    let json = """
    {"SPBluetoothDataType":[{"device_connected":[
      {"AirPods Pro":{"device_address":"AA","device_minorType":"Headphones","device_batteryLevelLeft":"90%","device_batteryLevelRight":"85%","device_batteryLevelCase":"40%"}},
      {"MX Master 3S":{"device_address":"BB","device_minorType":"Mouse"}},
      {"Magic Keyboard":{"device_address":"CC","device_minorType":"Keyboard","device_batteryLevelMain":"15%"}}],
      "device_not_connected":[{"Old Mouse":{"device_batteryLevelMain":"50%"}}]}]}
    """
    let devices = DeviceBattery.parse(Data(json.utf8))
    #expect(devices.map(\.name) == ["AirPods Pro", "Magic Keyboard"])
    #expect(devices[0].levels.map(\.label) == ["Case", "Left", "Right"])
    #expect(devices[1].levels == [.init(label: "", percent: 15)])
    #expect(devices[0].lowest == 40)
}

@Test func switchingRulesMatchAppsPowerAndOvernightSchedules() {
    let base = CoolingConfiguration()
    let app = AutomationRule(trigger: .app(bundleID: "com.apple.dt.Xcode", name: "Xcode"), profileName: "Performance", configuration: base)
    let battery = AutomationRule(trigger: .battery, profileName: "Quiet", configuration: base)
    let night = AutomationRule(trigger: .schedule(start: 22 * 60, end: 7 * 60), profileName: "Quiet", configuration: base)
    #expect(app.matches(runningApps: ["com.apple.dt.Xcode"], onBattery: nil, minute: 0))
    #expect(!app.matches(runningApps: [], onBattery: nil, minute: 0))
    #expect(battery.matches(runningApps: [], onBattery: true, minute: 0))
    #expect(!battery.matches(runningApps: [], onBattery: nil, minute: 0))
    #expect(night.matches(runningApps: [], onBattery: nil, minute: 23 * 60))
    #expect(night.matches(runningApps: [], onBattery: nil, minute: 6 * 60))
    #expect(!night.matches(runningApps: [], onBattery: nil, minute: 12 * 60))
    let data = try? JSONEncoder().encode([app, night])
    #expect(AutomationRule.load(from: data) == [app, night])
}

@Test func logitechHIDPPBatteryParsing() {
    // MX Master 3S over BLE: 85%, level flag "full", discharging.
    #expect(LogitechBattery.level(feature: 0x1004, parameters: [85, 8, 0, 0]) == .init(label: "", percent: 85))
    #expect(LogitechBattery.level(feature: 0x1004, parameters: [40, 4, 1, 1]) == .init(label: "Charging", percent: 40))
    #expect(LogitechBattery.level(feature: 0x1004, parameters: [0, 2, 0]) == .init(label: "", percent: 20))
    #expect(LogitechBattery.level(feature: 0x1000, parameters: [50, 30, 0]) == .init(label: "", percent: 50))
    #expect(LogitechBattery.level(feature: 0x1004, parameters: [0, 0, 0]) == nil)
}
