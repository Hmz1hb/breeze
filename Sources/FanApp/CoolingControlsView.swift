import FanCore
import SwiftUI

struct CoolingControlsView: View {
    @Bindable var model: AppModel
    @State private var profileName = ""
    @State private var saving = false
    @State private var boostMinutes = 5

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
                    Button { model.stage(preset) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: preset.symbol).font(.title3).foregroundStyle(BreezeStyle.mint)
                                Spacer()
                                Image(systemName: "arrow.down.right").foregroundStyle(.tertiary)
                            }
                            Text(preset.rawValue).font(.subheadline.weight(.semibold))
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32, alignment: .top)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .breezeGlass(interactive: true)
                            .contentShape(RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain).help("Load the \(preset.rawValue.lowercased()) curve into the editor")
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "timer").font(.title2).foregroundStyle(BreezeStyle.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.boostEndsAt == nil ? "A little extra cooling" : "Timed boost is active").font(.subheadline.weight(.semibold))
                    Text("Maximum speed, then back to macOS automatically.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.boostEndsAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(model.boostRemaining ?? "0:00").font(.title3.monospacedDigit())
                            .accessibilityLabel("Boost time remaining \(model.boostRemaining ?? "0:00")")
                    }
                    Button("End boost") { Task { await model.endTimedBoost() } }.breezeAction()
                        .disabled(model.busy)
                } else {
                    Picker("Boost duration", selection: $boostMinutes) {
                        ForEach([1, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }.labelsHidden().frame(width: 86)
                    Button("Start boost", systemImage: "play.fill") { Task { await model.startTimedBoost(minutes: boostMinutes) } }
                        .breezeAction(prominent: true)
                        .disabled(model.busy || model.snapshot?.canControl != true)
                }
            }.padding(16).breezeSurface()
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
}
