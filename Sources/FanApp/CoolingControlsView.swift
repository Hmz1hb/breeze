import FanCore
import SwiftUI

struct CoolingControlsView: View {
    @Bindable var model: AppModel
    @State private var profileName = ""
    @State private var saving = false
    @State private var boostMinutes = 5
    @State private var bounces: [CoolingPreset: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find your flow").font(.title3.weight(.semibold))
                    Text("Load a starting point, fine-tune it, then apply.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if model.savedProfiles.isEmpty { Text("No saved profiles yet") }
                    ForEach(model.savedProfiles) { profile in
                        Button(profile.name) { model.configuration = profile.configuration }
                    }
                    Divider()
                    Button("Save current profile…") { saving = true }
                } label: { Label("My profiles", systemImage: "bookmark") }
                    .fixedSize().breezeAction()
            }
            HStack(spacing: 12) {
                ForEach(CoolingPreset.allCases) { preset in
                    let staged = isStaged(preset)
                    Button {
                        model.stage(preset)
                        bounces[preset, default: 0] += 1
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: preset.symbol).font(.title3).foregroundStyle(BreezeStyle.mint)
                                Spacer()
                                Image(systemName: staged ? "checkmark.circle.fill" : "arrow.down.right")
                                    .foregroundStyle(staged ? AnyShapeStyle(BreezeStyle.mint) : AnyShapeStyle(.tertiary))
                                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                                    .symbolEffect(.bounce, value: reduceMotion ? 0 : bounces[preset, default: 0])
                                    .breezeAnimation(.settle, value: staged)
                            }
                            Text(preset.rawValue).font(.subheadline.weight(.semibold))
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32, alignment: .top)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .breezeGlass(interactive: true)
                    }
                    .buttonStyle(.breezeCard)
                    .accessibilityAddTraits(staged ? .isSelected : [])
                    .help("Load the \(preset.rawValue.lowercased()) curve into the editor")
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "timer").font(.title2).foregroundStyle(BreezeStyle.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.boostEndsAt == nil ? "A little extra cooling" : "Timed boost is active").font(.subheadline.weight(.semibold))
                        .contentTransition(.opacity)
                    Text("Maximum speed, then back to macOS automatically.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.boostEndsAt != nil {
                    HStack(spacing: 12) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(model.boostRemaining ?? "0:00").font(.title3.monospacedDigit())
                                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                                .breezeAnimation(.settle, value: model.boostRemaining)
                                .accessibilityLabel("Boost time remaining \(model.boostRemaining ?? "0:00")")
                        }
                        Button("End boost") { Task { await model.endTimedBoost() } }.breezeAction()
                            .disabled(model.busy)
                    }.transition(.breezeFade)
                } else {
                    HStack(spacing: 12) {
                        Picker("Boost duration", selection: $boostMinutes) {
                            ForEach([1, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                        }.labelsHidden().frame(width: 86)
                        Button("Start boost", systemImage: "play.fill") {
                            let minutes = boostMinutes
                            Task {
                                await model.startTimedBoost(minutes: minutes)
                                BoostSpan.record(model.boostEndsAt, minutes: minutes)
                            }
                        }
                        .breezeAction(prominent: true)
                        .disabled(model.busy || model.snapshot?.canControl != true)
                    }.transition(.breezeFade)
                }
            }
            .padding(16)
            .overlay(alignment: .bottom) {
                if let end = model.boostEndsAt {
                    // Drains along the row as the boost runs down.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        BreezeMeter(fraction: BoostSpan.fraction(until: end, now: context.date), height: 2)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 5)
                    .accessibilityHidden(true)
                    .transition(.breezeFade)
                }
            }
            .breezeAnimation(.settle, value: model.boostEndsAt != nil)
            .breezeSurface()
        }
        .sheet(isPresented: $saving) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your cooling library").font(.title2.weight(.semibold))
                Text("Save the settings currently in the editor. Loading a profile lets you review it before applying.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    TextField("Profile name", text: $profileName).textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Button("Save") { save() }.breezeAction(prominent: true)
                        .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
                if !model.savedProfiles.isEmpty {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(model.savedProfiles) { profile in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name).font(.subheadline.weight(.medium))
                                        Text(profile.configuration.mode.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Load") { model.configuration = profile.configuration; saving = false }
                                    Button { model.deleteProfile(profile.id) } label: { Image(systemName: "trash") }
                                        .help("Remove \(profile.name) from your library")
                                        .accessibilityLabel("Remove saved profile \(profile.name)")
                                }.padding(12).breezeSurface()
                            }
                        }
                    }.frame(maxHeight: 220)
                }
                HStack { Spacer(); Button("Done") { saving = false }.keyboardShortcut(.cancelAction) }
            }.padding(26).frame(width: 470).breezeAction()
        }
    }
    private func save() {
        if model.saveProfile(named: profileName) { profileName = "" }
    }
    /// The editor holds this preset's curve.
    private func isStaged(_ preset: CoolingPreset) -> Bool {
        let staged = preset.configuration(boostTemperature: model.configuration.boostTemperature)
        return model.configuration.mode == .curve &&
            model.configuration.points.map { [$0.temperature, $0.percent] } == staged.points.map { [$0.temperature, $0.percent] }
    }
}

/// Timed-boost length for the draining meter.
/// shortcut: AppModel keeps only the end date, so the length is recorded where Breeze's window starts a boost and
/// otherwise rounded up to the next duration option; store the start in AppModel if the drain must be exact.
@MainActor enum BoostSpan {
    private static var lengths: [Date: TimeInterval] = [:]

    static func record(_ end: Date?, minutes: Int) {
        if let end { lengths[end] = Double(minutes * 60) }
    }

    static func fraction(until end: Date, now: Date) -> Double {
        let remaining = max(end.timeIntervalSince(now), 0)
        let length = lengths[end] ?? Double(([1, 5, 10, 15, 30].first { Double($0 * 60) >= remaining } ?? 30) * 60)
        return remaining / max(length, 1)
    }
}
