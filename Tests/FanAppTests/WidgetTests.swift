import FanCore
import Foundation
import Testing
@testable import FanApp

@Test func widgetPresetsAndCustomSelectionsRoundTrip() throws {
    #expect(WidgetPreferences.simple.presetName == "Simple")
    #expect(WidgetPreferences.detailed.presetName == "Detailed")
    var custom = WidgetPreferences.detailed
    custom.metrics.remove(.gpu)
    custom.menuMetrics = []
    custom.sections.remove(.processes)
    custom.historySeconds = 600
    #expect(custom.presetName == "Custom")
    #expect(WidgetPreferences.load(from: try JSONEncoder().encode(custom)) == custom)
    #expect(WidgetPreferences.detailed.metrics.contains(.gpu))
    #expect(WidgetPreferences.detailed.sections.contains(.processes))
}

@Test func widgetRecoversFromInvalidPreferencesAndBoundsHistory() throws {
    #expect(WidgetPreferences.load(from: nil) == .simple)
    #expect(WidgetPreferences.load(from: Data("broken".utf8)) == .simple)
    var invalid = WidgetPreferences.detailed
    invalid.historySeconds = -1
    let restored = WidgetPreferences.load(from: try JSONEncoder().encode(invalid))
    #expect(restored.historySeconds == 300)
    #expect(restored.metrics == invalid.metrics)
    var empty = WidgetPreferences.simple
    empty.metrics = []; empty.sections = []; empty.menuMetrics = []
    #expect(WidgetPreferences.load(from: try JSONEncoder().encode(empty)) == empty)
}

@Test func detailedSamplingOnlyRunsForContentThatNeedsIt() {
    #expect(!WidgetPreferences.simple.needsActivityInMenuBar)
    #expect(!WidgetPreferences.simple.needsActivityInPopover)
    #expect(WidgetPreferences.detailed.needsActivityInPopover)
    var custom = WidgetPreferences.simple
    custom.menuMetrics = [.gpu]
    #expect(custom.needsActivityInMenuBar)
    custom.sections.insert(.processes)
    #expect(custom.needsActivityInPopover)
}

@MainActor @Test func widgetChangesPersistWithoutChangingCoolingSettings() throws {
    let suite = "BreezeWidgetTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    model.widgetPreferences = .detailed
    model.widgetPreferences.menuMetrics.remove(.cpu)
    model.widgetPreferences.sections.remove(.sensors)
    model.widgetPreferences.historySeconds = 120
    let restored = AppModel(defaults: defaults)
    #expect(restored.widgetPreferences == model.widgetPreferences)
    #expect(restored.widgetPreferences.presetName == "Custom")
    #expect(defaults.data(forKey: "coolingProfile") == nil)
    #expect(!model.enabled)
}

@MainActor @Test func widgetDistinguishesStoppedMissingAndFanlessHardware() throws {
    let suite = "BreezeWidgetTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    #expect(WidgetValues.value(.fans, model: model) == "—")
    #expect(WidgetValues.value(.temperature, model: model) == "—")
    model.snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"fans":[{"id":0,"current":0,"minimum":0,"maximum":5000,"mode":0}],
         "temperatures":[{"key":"Tc0D","celsius":61}],"thermalPressure":"nominal"}
        """.utf8))
    #expect(WidgetValues.value(.fans, model: model) == "0 RPM")
    #expect(WidgetValues.value(.temperature, model: model) == "61°C")
    model.sleeping = true
    #expect(WidgetValues.value(.fans, model: model) == "—")
    #expect(WidgetValues.value(.temperature, model: model) == "—")
    model.sleeping = false
    model.snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"fans":[],"temperatures":[],"thermalPressure":"nominal"}
        """.utf8))
    #expect(WidgetValues.value(.fans, model: model) == "Fanless")
}
