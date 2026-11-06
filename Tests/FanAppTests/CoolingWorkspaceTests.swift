import FanCore
import Foundation
import Testing
@testable import FanApp

@Test func coolingPresetsRemainOrderedAndKeepTheChosenHeatBoost() throws {
    let quiet = CoolingPreset.quiet.configuration(boostTemperature: 82)
    let balanced = CoolingPreset.balanced.configuration(boostTemperature: 82)
    let performance = CoolingPreset.performance.configuration(boostTemperature: 82)
    for configuration in [quiet, balanced, performance] {
        try configuration.validate()
        #expect(configuration.boostTemperature == 82)
        #expect(configuration.mode == .curve)
    }
    for temperature in stride(from: 35.0, through: 90.0, by: 1) {
        #expect(try quiet.curvePercent(at: temperature) <= balanced.curvePercent(at: temperature))
        #expect(try balanced.curvePercent(at: temperature) <= performance.curvePercent(at: temperature))
    }
}

private actor TestCoolingSession: CoolingSession {
    var commands: [Command] = []
    var rejectNext = false
    func rejectNextCommand() { rejectNext = true }
    func enable() -> Reply { Reply(ok: true, message: "", manual: false) }
    func request(_ command: Command) -> Reply {
        commands.append(command)
        if rejectNext {
            rejectNext = false
            return Reply(ok: false, message: "Restoration rejected", manual: true, percent: 100, mode: .manual)
        }
        let mode = command.configuration?.mode ?? .automatic
        return Reply(ok: true, message: "", manual: mode != .automatic,
                     percent: mode == .manual ? command.configuration?.manualPercent : nil, mode: mode)
    }
    func stop() {}
}

@MainActor @Test func savedProfilesPersistWithoutApplyingAndRejectDuplicateNames() throws {
    let suite = "BreezeTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = TestCoolingSession()
    let model = AppModel(defaults: defaults, session: session)
    model.stage(.quiet)
    #expect(model.saveProfile(named: "  Focus  "))
    #expect(!model.saveProfile(named: "focus"))
    #expect(!model.saveProfile(named: "   "))
    let loaded = AppModel(defaults: defaults, session: session)
    #expect(loaded.savedProfiles.count == 1)
    #expect(loaded.savedProfiles.first?.name == "Focus")
    #expect(loaded.savedProfiles.first?.configuration == model.configuration)
    #expect(defaults.data(forKey: "coolingProfile") == nil)
    loaded.deleteProfile(try #require(loaded.savedProfiles.first?.id))
    #expect(SavedCoolingProfile.load(from: defaults.data(forKey: "savedCoolingProfiles")).isEmpty)
}

@MainActor @Test func timedBoostExpiresWithoutReplacingTheDraftOrStartupProfile() async throws {
    let suite = "BreezeTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = TestCoolingSession()
    let model = AppModel(defaults: defaults, session: session)
    model.enabled = true
    model.stage(.balanced)
    await model.apply()
    let startup = defaults.data(forKey: "coolingProfile")
    model.stage(.quiet)
    let draft = model.configuration
    await model.startTimedBoost(minutes: 5)
    let deadline = try #require(model.boostEndsAt)
    #expect(model.activeMode == .manual)
    #expect(model.appliedPercent == 100)
    #expect(model.configuration == draft)
    #expect(defaults.data(forKey: "coolingProfile") == startup)
    // An unfinished editor must never prevent the timer from returning control to macOS.
    model.configuration.boostTemperature = .nan
    await model.finishExpiredBoost(now: deadline.addingTimeInterval(-1))
    #expect(model.boostEndsAt != nil)
    await model.finishExpiredBoost(now: deadline.addingTimeInterval(1))
    #expect(model.boostEndsAt == nil)
    #expect(model.activeMode == .automatic)
    #expect(model.configuration.points == draft.points)
    #expect(model.configuration.boostTemperature.isNaN)
    #expect(defaults.data(forKey: "coolingProfile") == startup)
    #expect(await session.commands.count == 3)
}

@MainActor @Test func rejectedRestorationKeepsTheTimerForRetryAndApplyingCancelsIt() async throws {
    let suite = "BreezeTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = TestCoolingSession()
    let model = AppModel(defaults: defaults, session: session)
    model.enabled = true
    await model.startTimedBoost(minutes: 1)
    let deadline = try #require(model.boostEndsAt)
    await session.rejectNextCommand()
    await model.finishExpiredBoost(now: deadline.addingTimeInterval(1))
    #expect(model.boostEndsAt == deadline)
    #expect(model.message == "Restoration rejected")
    model.busy = true
    await model.finishExpiredBoost(now: deadline.addingTimeInterval(2))
    #expect(await session.commands.count == 2)
    model.busy = false
    await model.finishExpiredBoost(now: deadline.addingTimeInterval(3))
    #expect(model.boostEndsAt == nil)
    #expect(model.activeMode == .automatic)
    await model.startTimedBoost(minutes: 1)
    model.stage(.performance)
    await model.apply()
    #expect(model.boostEndsAt == nil)
    #expect(model.activeMode == .curve)
}

@MainActor @Test func historyExportFiltersTheRangeAndLeavesUnavailableCountersEmpty() throws {
    let suite = "BreezeTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    model.historySeconds = 120
    model.history = [
        .init(date: .now.addingTimeInterval(-200), temperature: 99, rpm: 5000, cpu: 80),
        .init(date: .now.addingTimeInterval(-30), temperature: 55.5, rpm: 2100, cpu: nil),
        .init(date: .now, temperature: 60, rpm: 2400, cpu: .nan)
    ]
    let csv = model.historyCSV
    #expect(!csv.contains("99.0"))
    #expect(csv.contains(",55.5,2100.0,\n"))
    #expect(!csv.contains("nan"))
    #expect(csv.split(separator: "\n").count == 3)
}
