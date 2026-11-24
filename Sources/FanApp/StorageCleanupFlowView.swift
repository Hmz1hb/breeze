import StorageCore
import SwiftUI

// Intent: reclaim space without making the Mac owner manage a chain of dialogs.
// Palette: Breeze mint for readiness, system orange for work to resolve, red for removal.
// Depth: quiet system surfaces with the existing subtle borders. SF makes decisions
// readable and sizes comparable. Four-point spacing, 16-point groups, 28-point margins.
struct StorageCleanupReview: View {
    @Bindable var model: StorageCleanupModel
    private var permanent: [CleanupEntry] { model.reviewEntries.filter { $0.action.isPermanent } }
    private var trash: [CleanupEntry] { model.reviewEntries.filter { !$0.action.isPermanent } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your cleanup plan").font(.title2.weight(.semibold))
                    Text("Keep anything you’re unsure about. Nothing changes until you approve removal.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(cleanupSize(model.reviewBytes)).font(.system(size: 28, weight: .light, design: .rounded))
                        .breezeNumeric(Double(model.reviewBytes))
                    Text("\(model.reviewEntries.count) items · estimated size").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 28).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    readiness.breezeAnimation(.settle, value: readinessPhase)
                    if let summary = model.assistantReviewSummary {
                        Label("Suggested by your assistant", systemImage: "sparkles").font(.subheadline.weight(.medium))
                        Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !trash.isEmpty {
                        removalGroup("Move to Trash", symbol: "trash", explanation: "Restore these files in Finder if you change your mind. Disk space is released when you empty Trash.", entries: trash)
                            .transition(.breezeFade)
                    }
                    if !permanent.isEmpty {
                        removalGroup("Remove permanently", symbol: "exclamationmark.triangle", explanation: "These tools delete data directly. It won’t appear in Trash.", entries: permanent)
                            .transition(.breezeFade)
                        Toggle("I understand that these \(permanent.count) tool actions permanently remove data and can’t be undone in Trash.", isOn: $model.permanentConsent)
                            .toggleStyle(.checkbox).font(.caption).fixedSize(horizontal: false, vertical: true)
                            .padding(16).breezeSurface(radius: 12).disabled(model.busy)
                    }
                }.padding(.horizontal, 28).padding(.bottom, 20)
            }
            Divider()
            HStack(spacing: 16) {
                Button("Back to choices", systemImage: "arrow.left") { model.backToChoices() }
                    .keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer(minLength: 8)
                Label(model.canRemoveReviewed ? "Your plan is ready." : "Resolve the steps above to continue.",
                      systemImage: model.canRemoveReviewed ? "checkmark.shield" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(model.canRemoveReviewed ? BreezeStyle.mint : Color.orange)
                    .contentTransition(.symbolEffect(.replace))
                    .breezeAnimation(.settle, value: model.canRemoveReviewed)
                Button(permanent.isEmpty ? "Move to Trash" : "Remove reviewed items", role: .destructive) { model.cleanReviewed() }
                    .breezeAction(prominent: true)
                    .disabled(!removeEnabled)
                    .breezeAnimation(.settle, value: removeEnabled)
            }.padding(.horizontal, 28).padding(.vertical, 16)
        }.breezeAction()
    }

    private var removeEnabled: Bool { model.canRemoveReviewed && (permanent.isEmpty || model.permanentConsent) }

    private var readinessPhase: Int {
        if model.checkingProcesses { return 0 }
        if !model.processBlockers.isEmpty { return 1 }
        if model.reviewNeedsRefresh { return 2 }
        return model.reviewReady ? 3 : 4
    }

    @ViewBuilder private var readiness: some View {
        if model.checkingProcesses {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Checking running apps and tools").font(.subheadline.weight(.medium))
                    Text("Breeze checks what needs to close before your files can move.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel check") { model.cancel() }.disabled(model.cancellationRequested)
            }.padding(16).breezeSurface(radius: 14).transition(.breezeFade)
        } else if !model.processBlockers.isEmpty {
            processReview.transition(.breezeFade)
        } else if model.reviewNeedsRefresh {
            VStack(alignment: .leading, spacing: 12) {
                Label("One more step before cleanup", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text("Some items were in use during the scan. If a simulator is still running, shut it down in Simulator. Breeze will refresh your choices before removal.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(model.reviewEntries.filter { $0.blockedReason != nil }) { entry in
                    Text("\(entry.title): \(entry.blockedReason ?? "")").font(.caption).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button("Keep in-use items for later") { model.keepInUseItems() }
                    Spacer()
                    Button("Refresh review", systemImage: "arrow.clockwise") { model.refreshReview() }.breezeAction(prominent: true)
                }
            }.padding(16).breezeSurface(radius: 14).transition(.breezeFade)
        } else if model.reviewReady {
            Label("Ready. Breeze will check again immediately before removal.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(BreezeStyle.mint).padding(14).frame(maxWidth: .infinity, alignment: .leading).breezeSurface(radius: 12)
                .transition(.breezeFade)
        } else {
            HStack(spacing: 12) {
                Label("The running-process check hasn’t finished.", systemImage: "info.circle").font(.caption)
                Spacer()
                Button("Check again") { model.refreshProcesses() }
            }.padding(16).breezeSurface(radius: 14).transition(.breezeFade)
        }
    }

    private var processReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Close what’s in use", systemImage: "app.badge.clock").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text("These apps or tools may be using \(model.affectedReviewIDs.count) of your items. Save your work before stopping them, or keep those items for later.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("A matching tool can serve several projects. Stopping it can interrupt builds, servers or downloads.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.processBlockers) { process in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("Stop \(process.name), PID \(process.id)", isOn: Binding(
                            get: { model.selectedProcesses.contains(process.id) },
                            set: { value in
                                if value { model.selectedProcesses.insert(process.id) }
                                else { model.selectedProcesses.remove(process.id) }
                            }))
                            .toggleStyle(.checkbox).labelsHidden().disabled(!process.canStop)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(process.name).font(.subheadline.weight(.medium))
                                Text("PID \(process.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(process.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            Text(model.reviewEntries.filter { process.affectedEntryIDs.contains($0.id) }.map(\.title).joined(separator: ", "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            if !process.canStop {
                                Label("Protected because it runs Breeze or belongs to another user.", systemImage: "lock")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            BreezeDisclosure("Full command") {
                                Text(process.command).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                            }.font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
            }
            Text("Breeze asks apps to quit normally and sends tools a stop request. It then refreshes this plan. Stopping a process doesn’t remove your files.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep these items for later") { model.keepInUseItems() }
                Menu {
                    Button("Check running processes again") { model.refreshProcesses() }
                    Button("Open Activity Monitor") { model.openActivityMonitor() }
                } label: { Label("More", systemImage: "ellipsis") }
                Spacer(minLength: 0)
                Button("Stop selected & refresh", role: .destructive) { model.stopReviewedProcesses() }
                    .breezeAction(prominent: true).disabled(model.selectedProcesses.isEmpty)
            }
        }.padding(16).breezeSurface(radius: 14)
    }

    private func removalGroup(_ title: String, symbol: String, explanation: String, entries: [CleanupEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                    .foregroundStyle(entries.first?.action.isPermanent == true ? Color.orange : Color.primary)
                Spacer()
                Text("\(entries.count) items").font(.caption).foregroundStyle(.secondary)
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            StorageCleanupIcon(model: model, entry: entry, size: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(.subheadline.weight(.medium))
                                if entry.applicationURL != nil {
                                    Text("Removes the installed application").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Text(entry.bytes > 0 ? cleanupSize(entry.bytes) : "Size unavailable").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            // Row leaves with the exit fade; the group closes with settle.
                            Button("Keep") { BreezeMotion.animate(.settle) { model.keepReviewedItem(entry) } }.disabled(model.busy)
                                .accessibilityLabel("Keep \(entry.title)")
                        }
                        Text(entry.recovery).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let reason = model.assistantReviewReasons[entry.id] {
                            Text("AI suggestion: " + reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        BreezeDisclosure("What’s included") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(entry.detail)
                                Text(entry.action.explanation)
                                if let context = entry.context {
                                    ForEach(Array(context.sections.enumerated()), id: \.offset) { _, section in
                                        Text(section.title).fontWeight(.medium)
                                        Text(section.text)
                                    }
                                }
                                ForEach(entry.resources, id: \.url) { resource in
                                    Text(resource.url.path).font(.caption.monospaced())
                                }
                                if !entry.resources.isEmpty { Button("Show in Finder") { model.reveal(entry) } }
                            }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.caption)
                    }.padding(16).transition(.breezeFade)
                    if entry.id != entries.last?.id { Divider() }
                }
            }.breezeSurface(radius: 14)
        }
    }
}

// Progress occupies the same workspace as choices and review. Scanning has an
// unknown duration; only removal reports measured item advancement, never fake time.
struct StorageCleanupActivityView: View {
    let model: StorageCleanupModel
    // Stage and path text, copied from the model at 4 Hz so fast scans stay readable.
    @State private var stage: String
    @Environment(\.breezeMotionLevel) private var level

    init(model: StorageCleanupModel) {
        self.model = model
        _stage = State(initialValue: model.progress)
    }

    private var phase: Int { model.cleaning ? 2 : model.stoppingProcesses ? 1 : 0 }
    private var cancelTitle: String {
        model.cancellationRequested ? "Stopping…" : model.cleaning ? "Stop cleanup" : model.stoppingProcesses ? "Stop waiting" : "Cancel scan"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 16)
            Image(systemName: model.cleaning ? "trash" : model.stoppingProcesses ? "app.badge.clock" : "internaldrive")
                .font(.system(size: 40, weight: .light)).foregroundStyle(BreezeStyle.mint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, isActive: phase == 0 && model.scanning && level.isActive)
                .breezeAnimation(.settle, value: phase)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.cleaning ? "Clearing your reviewed items" : model.stoppingProcesses ? "Closing selected apps and tools" : "Finding what you can clear")
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .contentTransition(.opacity)
                    .breezeAnimation(.settle, value: phase)
                Text(model.cleaning ? "Your choices are being applied. Anything that can’t be removed will appear in the results." : model.stoppingProcesses ? "An app may ask you to save your work. Breeze will refresh your plan when this step finishes." : "Checking caches, projects, apps and local tools. Your files stay where they are.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                if model.cleaning && model.cleaningTotal > 0 {
                    BreezeMeter(fraction: Double(model.cleaningCompleted) / Double(model.cleaningTotal))
                        .accessibilityLabel("Cleanup progress")
                    Text("\(model.cleaningCompleted) of \(model.cleaningTotal) items processed").font(.caption).breezeLive().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(stage).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).breezeSurface(radius: 14)
            Button(cancelTitle) { model.cancel() }
                .disabled(model.cancellationRequested)
                .contentTransition(.opacity)
                .breezeAnimation(.settle, value: cancelTitle)
            if model.cleaning || model.stoppingProcesses {
                Text("Completed changes stay applied. Breeze refreshes the results after stopping.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
        }.frame(maxWidth: 680, alignment: .leading).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                if stage != model.progress { stage = model.progress }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
    }
}

struct StorageCleanupReceiptView: View {
    @Bindable var model: StorageCleanupModel
    let receipt: StorageCleanupModel.Receipt
    private var hasChanges: Bool { receipt.trashedLocations > 0 || receipt.permanentActions > 0 }
    private var success: Bool { !receipt.stopped && receipt.failures.isEmpty }
    // Finish sequence plays once per receipt; Reduce Motion and later shows start at rest.
    @State private var sealShown: Bool
    @State private var settled: Bool
    @State private var countUp = false

    init(model: StorageCleanupModel, receipt: StorageCleanupModel.Receipt) {
        self.model = model
        self.receipt = receipt
        let key = "cleanup.receipt.\(receipt.trashedLocations).\(receipt.permanentActions).\(receipt.completed.map(\.id).hashValue)"
        let play = !BreezeMotion.systemReduceMotion && BreezeMotion.firstTime(key)
        _sealShown = State(initialValue: !play)
        _settled = State(initialValue: !play)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack { if sealShown { seal } }
                            .frame(width: 40, height: 40)
                            .scaleEffect(sealShown || !success ? 1 : 0.6)
                            .breezePulse(trigger: success && sealShown)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(receipt.stopped ? "Cleanup stopped" : receipt.failures.isEmpty ? "Cleanup complete" : "Some items need attention")
                                .font(.system(size: 26, weight: .medium, design: .rounded))
                            Text(hasChanges ? "Here’s what changed on your Mac." : "No removal actions were completed.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.opacity(settled ? 1 : 0)
                    }
                    Group {
                        HStack(alignment: .top, spacing: 32) {
                            resultCount(receipt.trashedLocations, label: "locations moved to Trash")
                            resultCount(receipt.permanentActions, label: "permanent tool removals")
                            if receipt.bytes > 0 { resultValue(label: "in completed items · estimated") { Text(cleanupSize(receipt.bytes)) } }
                            Spacer(minLength: 0)
                        }.padding(20).breezeSurface(radius: 14)
                        if receipt.trashedLocations > 0 {
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Your files are in Trash").font(.subheadline.weight(.medium))
                                    Text("Restore a file in Finder if you need it back. Space used by Trash is released when you empty it in Finder.")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button("Open Trash", systemImage: "trash") { model.openTrash() }
                            }.padding(16).breezeSurface(radius: 14)
                        }
                        if !receipt.failures.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("What still needs attention", systemImage: "exclamationmark.circle").font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                                ForEach(Array(receipt.failures.enumerated()), id: \.offset) { _, failure in
                                    Text(failure).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                Text("A partially completed item may have files in Trash. Check its refreshed details before trying again.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).breezeSurface(radius: 14)
                        }
                        if !receipt.completed.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Completed items").font(.subheadline.weight(.medium))
                                ForEach(receipt.completed) { entry in
                                    HStack(spacing: 12) {
                                        Image(systemName: entry.action.isPermanent ? "checkmark.circle" : "trash").foregroundStyle(.secondary)
                                        Text(entry.title).font(.caption)
                                        Spacer()
                                        Text(entry.action.isPermanent ? "Removed permanently" : "In Trash").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if model.scanning {
                            HStack(spacing: 12) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Refreshing cleanup results").font(.caption.weight(.medium))
                                    Text(model.progress).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Button("Stop refresh") { model.cancel() }.disabled(model.cancellationRequested)
                            }.padding(16).breezeSurface(radius: 14)
                        }
                    }.opacity(settled ? 1 : 0)
                }.padding(28)
            }
            Divider()
            HStack(spacing: 12) {
                if model.requiresRescan && !model.busy {
                    Button("Refresh results") { model.scan(preserving: receipt.remainingIDs, keepingReceipt: true) }
                }
                Spacer()
                if !receipt.remainingIDs.isEmpty {
                    Button("Review remaining items") { model.retryRemaining() }
                        .disabled(model.busy || model.requiresRescan || model.selected.isEmpty)
                }
                Button("Back to cleanup") { model.finishCleanup() }.breezeAction(prominent: true).disabled(model.busy)
            }.padding(.horizontal, 28).padding(.vertical, 16)
        }.breezeAction()
        .task {
            guard !settled else { return }
            if success {
                // The seal lands alone first, then the title and results arrive together.
                BreezeMotion.animate(.lift) { sealShown = true }
                try? await Task.sleep(for: .seconds(BreezeMotion.s))
                BreezeMotion.animate(.enter) { settled = true; countUp = true }
            } else {
                BreezeMotion.animate(.settle) { sealShown = true; settled = true }
            }
        }
    }

    @ViewBuilder private var seal: some View {
        let image = Image(systemName: success ? "checkmark.circle" : "exclamationmark.circle")
            .font(.system(size: 36, weight: .light)).foregroundStyle(success ? BreezeStyle.mint : Color.orange)
        if #available(macOS 26, *) {
            image.transition(.symbolEffect(.drawOn))
        } else {
            image.transition(.symbolEffect(.appear))
        }
    }

    private func resultCount(_ value: Int, label: String) -> some View {
        resultValue(label: label) {
            if countUp {
                BreezeCountUp(Double(value)) { "\(Int($0.rounded()))" }
            } else {
                Text("\(value)")
            }
        }
    }

    private func resultValue<Value: View>(label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            value().font(.system(size: 24, weight: .light, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
