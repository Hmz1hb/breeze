import AppKit
import StorageCore
import SwiftUI

func cleanupSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct StorageCleanupIcon: View {
    let model: StorageCleanupModel
    let entry: CleanupEntry
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: entry.category.symbol)
                    .font(.system(size: size * 0.6)).foregroundStyle(BreezeStyle.mint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: "\(entry.id):\(model.inventory?.finished.timeIntervalSince1970 ?? 0)") {
            image = model.appIcon(for: entry)
        }
    }
}

extension CleanupRisk {
    var color: Color {
        switch self { case .rebuildable: BreezeStyle.mint; case .review: .orange; case .personal: .secondary }
    }
    var symbol: String {
        switch self { case .rebuildable: "arrow.triangle.2.circlepath"; case .review: "exclamationmark.circle"; case .personal: "person.crop.circle" }
    }
}

// Intent: a Mac owner deciding which tool data can go, with evidence beside
// each choice. Keep Breeze's mint actions, SF typography, quiet material surfaces
// and four-point spacing. Category totals locate space; recovery text informs removal.
struct StorageCleanupView: View {
    @Bindable var model: StorageCleanupModel
    @State private var showingFolders = false
    @State private var showingIssues = false
    @AppStorage("cleanupAssistantClient") private var assistantClient = "codex"

    var body: some View {
        VStack(spacing: 0) {
            journey
            if let message = model.message { messageBanner(message) }
            if let receipt = model.receipt {
                StorageCleanupReceiptView(model: model, receipt: receipt)
            } else if model.scanning || model.cleaning || model.stoppingProcesses {
                StorageCleanupActivityView(model: model)
            } else if model.showingReview {
                StorageCleanupReview(model: model)
            } else if let inventory = model.inventory {
                assistantNotice
                results(inventory)
                footer
            } else {
                introduction
            }
        }
        .breezeAction()
        .sheet(isPresented: $model.showingAssistant, onDismiss: {
            if model.assistantReviewRequested {
                model.assistantReviewRequested = false
                model.reviewAssistantProposal()
            }
        }) { StorageCleanupAssistantView(model: model) }
        .sheet(item: $model.inspected) { entry in StorageCleanupDetails(model: model, entry: entry) }
        .sheet(isPresented: $showingFolders) { projectFolders }
        .sheet(isPresented: $showingIssues) { scanIssues }
        .onChange(of: model.scope) { model.visibleRows = 100 }
        .onChange(of: model.risk) { model.visibleRows = 100 }
        .onChange(of: model.search) { model.visibleRows = 100 }
        .task {
            while !Task.isCancelled {
                model.receiveAssistantProposal()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private var journey: some View {
        HStack(spacing: 12) {
            ForEach(Array(["Scan", "Choose", "Review", "Finish"].enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    Image(systemName: index < model.workflowStep ? "checkmark.circle.fill" : "\(index + 1).circle\(index == model.workflowStep ? ".fill" : "")")
                        .foregroundStyle(index <= model.workflowStep ? BreezeStyle.mint : Color.secondary)
                    Text(title).font(.caption.weight(index == model.workflowStep ? .semibold : .regular))
                        .foregroundStyle(index == model.workflowStep ? .primary : .secondary)
                }.accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(index + 1), \(title)\(index == model.workflowStep ? ", current step" : "")")
                if index < 3 { Rectangle().fill(.separator).frame(maxWidth: 48).frame(height: 1).accessibilityHidden(true) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 28).padding(.bottom, 20)
    }

    @ViewBuilder private var assistantNotice: some View {
        if model.assistantRunning {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("\(model.assistantClientName ?? "Your assistant") is finding cleanup opportunities…").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                Button("Details") { model.showingAssistant = true }
                Button("Stop analysis") { model.cancelAssistantAnalysis() }
            }.padding(12).breezeSurface(radius: 12).padding(.horizontal, 28).padding(.bottom, 12)
        }
        if model.assistantStatusVisible, !model.assistantRunning, model.assistantProposal == nil,
           let status = model.assistantStatus {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(BreezeStyle.mint)
                Text(status).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button("AI options") { model.showingAssistant = true }
            }.padding(12).breezeSurface(radius: 12).padding(.horizontal, 28).padding(.bottom, 12)
        }
        if let proposal = model.assistantProposal {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(BreezeStyle.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your assistant suggested \(proposal.items.count) items").font(.subheadline.weight(.medium))
                    Text(proposal.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") { model.dismissAssistantProposal() }
                Button("Review suggestions") { model.reviewAssistantProposal() }.breezeAction(prominent: true)
            }.padding(14).breezeSurface(radius: 12).padding(.horizontal, 28).padding(.bottom, 12)
        }
    }

    private var introduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "internaldrive").font(.system(size: 40, weight: .light)).foregroundStyle(BreezeStyle.mint)
                    Text("Make room. Keep what matters.").font(.system(size: 28, weight: .medium, design: .rounded))
                    Text("Breeze finds caches, generated files and other storage you can review. Start with what can be rebuilt, then decide whether to go further.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 20) {
                    feature("Find the space", symbol: "magnifyingglass", detail: "Scan virtual devices, system images, Downloads installers and duplicates, tool caches, projects, models and apps.")
                    feature("Choose what goes", symbol: "checklist", detail: "See what each item is, how it comes back, and whether an app is using it.")
                    feature("Review, then clear", symbol: "trash", detail: "Files move to Trash. Permanent tool removals are clearly separated and need your approval.")
                }
                HStack(spacing: 12) {
                    Button("Find cleanup items", systemImage: "magnifyingglass") { model.scan() }.breezeAction(prominent: true)
                    Button("Project folders…") { showingFolders = true }
                }
                Label("Scanning stays on this Mac and doesn’t change your files.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 760, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func feature(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(BreezeStyle.mint).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(BreezeStyle.mint)
            ScrollView { Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 100)
            Button { model.message = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss cleanup message")
        }.padding(12).breezeSurface(radius: 12).padding(.horizontal, 28).padding(.bottom, 12)
    }

    private func results(_ inventory: CleanupInventory) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose what to clear").font(.title2.weight(.semibold))
                    Text("\(model.entries.count.formatted()) items found · scanned \(inventory.finished.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Project folders…") { showingFolders = true }.disabled(model.busy)
                Button("Rescan", systemImage: "arrow.clockwise") { model.scan(preserving: model.selected) }.disabled(model.busy)
            }
            if model.requiresRescan {
                HStack(spacing: 12) {
                    Label("These results need a fresh scan before you continue.", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Refresh results") { model.scan(preserving: model.selected) }
                }.padding(12).breezeSurface(radius: 12)
            } else {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Start with rebuildable items").font(.subheadline.weight(.medium))
                        Text("Caches and generated files can come back when needed. Rebuilding may take time or a download.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(cleanupSize(model.suggestedEntries.filter { $0.blockedReason == nil }.reduce(0) { $0 + $1.bytes }))
                            .font(.title3.weight(.medium)).monospacedDigit()
                        Text("available to select").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Select rebuildable") { model.selectRebuildable() }
                        .disabled(model.suggestedEntries.allSatisfy { $0.blockedReason != nil || model.selected.contains($0.id) })
                }.padding(16).breezeSurface(radius: 14)
            }
            if !inventory.issues.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(inventory.hasPermissionIssues ? "Some locations couldn’t be accessed. Your results may be incomplete." : "Some locations were skipped during the scan.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("\(inventory.issues.count) scan notes") { showingIssues = true }
                }
            }
            BreezeDisclosure("AI priorities (optional)") {
                TextField("For example: reclaim 30 GB; keep my current iOS device and local models", text: $model.assistantGoal, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder).disabled(model.assistantRunning)
            }.font(.caption)
            HStack(alignment: .top, spacing: 20) {
                categories.frame(width: 174)
                VStack(alignment: .leading, spacing: 12) {
                    filters
                    Text(scopeDescription).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if model.visibleEntries.isEmpty {
                                ContentUnavailableView("No matching items", systemImage: "checkmark.circle", description: Text("Try another category or clear your search and filters."))
                                    .padding(.vertical, 28)
                                if !model.search.isEmpty || model.risk != nil {
                                    Button("Clear filters") { model.search = ""; model.risk = nil }.padding(.bottom, 16)
                                }
                            }
                            ForEach(CleanupCategory.allCases, id: \.self) { category in
                                let items = Array(model.visibleEntries.prefix(model.visibleRows)).filter { $0.category == category }
                                if !items.isEmpty {
                                    HStack {
                                        Text(category.rawValue).font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(cleanupSize(items.reduce(0) { $0 + $1.bytes })).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    }.padding(.vertical, 12)
                                    ForEach(items) { entry in
                                        entryRow(entry)
                                        Divider()
                                    }
                                }
                            }
                            if model.visibleEntries.count > model.visibleRows {
                                Button("Show more (\(model.visibleEntries.count - model.visibleRows) remaining)") { model.visibleRows += 100 }.padding(.vertical, 12)
                            }
                            Text("Sizes are estimates. Shared files and Trash affect the space your Mac recovers. Open an item for its paths, dates and recovery details.")
                                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 16)
                        }
                    }
                }
            }
        }.padding(.horizontal, 28).frame(maxHeight: .infinity)
    }

    private var scopeDescription: String {
        switch model.scope {
        case .suggested: "Rebuildable files only. Select an in-use item to review its running apps before cleanup."
        case .inUse: "These items need an app or tool to stop first. You can handle that during review."
        case .selected: "Your choices across every category. Open an item for details, or uncheck it to keep it."
        case .category(.applications): "Selecting an application removes the installed app itself. Related files are separate choices."
        default: "Review recovery details before selecting apps, personal data or permanent removals."
        }
    }

    private var categories: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                categoryButton(.suggested, title: "Rebuildable", symbol: "arrow.triangle.2.circlepath")
                categoryButton(.all, title: "Everything", symbol: "square.grid.2x2")
                categoryButton(.inUse, title: "In use", symbol: "app.badge.clock")
                categoryButton(.selected, title: "Selected", symbol: "checkmark.circle")
                Text("BY TYPE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
                ForEach(CleanupCategory.allCases, id: \.self) { category in
                    categoryButton(.category(category), title: category.rawValue, symbol: category.symbol)
                }
            }
        }
    }

    private func categoryButton(_ scope: StorageCleanupModel.Scope, title: String, symbol: String) -> some View {
        let entries = model.entries(for: scope)
        return Button { model.scope = scope; model.risk = nil } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption.weight(.medium))
                    Text("\(entries.count) · \(cleanupSize(entries.reduce(0) { $0 + $1.bytes }))").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(model.scope == scope ? BreezeStyle.mint.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityAddTraits(model.scope == scope ? .isSelected : [])
    }

    private var filters: some View {
        HStack(spacing: 12) {
            TextField("Search name, app, project or path", text: $model.search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search cleanup items")
            Picker("Show", selection: $model.risk) {
                Text("All items").tag(nil as CleanupRisk?)
                ForEach(CleanupRisk.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.frame(width: 160).labelsHidden()
        }
    }

    private func entryRow(_ entry: CleanupEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(entry.title)", isOn: Binding(get: { model.selected.contains(entry.id) }, set: { _ in model.toggle(entry) }))
                .toggleStyle(.checkbox).labelsHidden().padding(.top, 4)
                .disabled(model.busy || model.requiresRescan || !model.canSelect(entry))
            Button { model.inspected = entry } label: {
                HStack(alignment: .top, spacing: 12) {
                    StorageCleanupIcon(model: model, entry: entry, size: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(entry.bytes > 0 ? cleanupSize(entry.bytes) : "—").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            if entry.applicationURL != nil { Label("Remove application", systemImage: "app.badge").foregroundStyle(.orange) }
                            Label(entry.risk.rawValue, systemImage: entry.risk.symbol).foregroundStyle(entry.risk.color)
                            if entry.action.isPermanent { Label("Permanent", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        }.font(.caption2)
                        if let context = entry.context {
                            Text(context.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let blocked = entry.blockedReason {
                            Label("In use · resolve during review", systemImage: "app.badge.clock").font(.caption2).foregroundStyle(.orange).help(blocked)
                        } else {
                            Text(entry.recovery).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Inspect details, related projects, recovery and full paths")
        }.padding(.vertical, 14).padding(.horizontal, 4)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selected.isEmpty ? "Choose items to continue" : "\(model.selected.count) selected · \(cleanupSize(model.selectedBytes)) estimated")
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                    Text(model.selectedEntries.contains { $0.blockedReason != nil } ? "Running apps will be handled in review." : "You’ll review removal and recovery before anything changes.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Clear") { model.clearSelection() }.disabled(model.busy || model.selected.isEmpty)
                Spacer(minLength: 8)
                Button { model.showingAssistant = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("AI options and assistant preference").accessibilityLabel("AI options")
                // Click runs the saved assistant; the arrow switches it.
                Menu {
                    Picker("Assistant", selection: $assistantClient) {
                        ForEach(CleanupAssistantClient.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                    }.pickerStyle(.inline)
                } label: {
                    Label("Ask \(CleanupAssistantClient.detected(preferred: assistantClient)?.name ?? "AI")", systemImage: "sparkles")
                } primaryAction: { model.askAssistant() }
                    .fixedSize()
                    .help("Click to analyze. Use the arrow to choose Codex or Claude Code.")
                    .disabled(model.busy || model.assistantRunning || model.requiresRescan)
                Button("Review selection", systemImage: "arrow.right") { model.prepareReview() }
                    .breezeAction(prominent: true).disabled(model.selected.isEmpty || model.busy || model.requiresRescan)
            }.padding(.horizontal, 28).padding(.vertical, 16)
        }
    }

    private var projectFolders: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Project folders").font(.title2.weight(.semibold))
            Text("The cleanup scan looks for recognized dependencies and build output in these folders, up to 24 levels deep. Add a project root anywhere inside your home folder. Folder choices last for this app session.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.projectRoots.isEmpty { Text("No project folders added. Tool caches and apps are still scanned.").foregroundStyle(.secondary) }
                    ForEach(model.projectRoots, id: \.path) { url in
                        HStack {
                            Text(url.path).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button { model.removeProjectRoot(url) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove \(url.lastPathComponent) from project scan").disabled(model.busy)
                        }
                    }
                }
            }
            HStack {
                Button("Add folders…") { model.addProjectFolder() }.disabled(model.busy)
                Spacer()
                Button("Done") { showingFolders = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 650, height: 380).breezeAction()
    }

    private var scanIssues: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan notes").font(.title2.weight(.semibold))
            Text("Some items were skipped. Linked paths, sockets, special files and unavailable tools can limit cleanup even when Full Disk Access is enabled.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.inventory?.hasPermissionIssues == true {
                Text("macOS also denied access to one or more locations. Check Full Disk Access for Breeze. If it is already enabled, quit and reopen Breeze, then scan again. Folder permissions may still restrict access.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array((model.inventory?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                        Text(issue).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }
            HStack {
                if model.inventory?.hasPermissionIssues == true {
                    Button("Full Disk Access settings") { model.openPrivacySettings() }
                }
                Spacer()
                Button("Done") { showingIssues = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 700, height: 480).breezeAction()
    }
}

private struct StorageCleanupDetails: View {
    @Bindable var model: StorageCleanupModel
    let entry: CleanupEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                StorageCleanupIcon(model: model, entry: entry, size: 48)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Label(entry.risk.rawValue, systemImage: entry.risk.symbol).font(.caption).foregroundStyle(entry.risk.color)
                }
                Spacer()
                Text(entry.bytes > 0 ? cleanupSize(entry.bytes) : "Size unavailable").font(.title3).monospacedDigit()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detail("What it is", entry.detail)
                    if let context = entry.context {
                        ForEach(Array(context.sections.enumerated()), id: \.offset) { _, section in
                            detail(section.title, section.text)
                        }
                    }
                    detail("How it comes back", entry.recovery)
                    detail(entry.action.isPermanent ? "Permanent action" : "Removal", entry.action.explanation)
                    if let lastOpened = entry.lastOpened { detail("Last opened · reported by Spotlight", lastOpened.formatted(date: .abbreviated, time: .shortened)) }
                    else { detail("Last opened", "Unknown. macOS has not supplied a date; this does not mean the item is unused.") }
                    if entry.applicationURL == nil, let lastUsed = entry.ownerLastUsed {
                        detail("Owning app last used · Spotlight", lastUsed.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let modified = entry.modified { detail("Most recent file change", modified.formatted(date: .abbreviated, time: .shortened)) }
                    detail("About dates", "Spotlight records opens through LaunchServices, not every CLI or background read. Creation and modification dates are not last-use dates. Filesystem access dates are weak evidence and may reflect background activity.")
                    if let reason = entry.blockedReason { detail("Before cleanup", reason) }
                    if !entry.resources.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Locations included").font(.subheadline.weight(.semibold))
                            ForEach(entry.resources, id: \.url) { resource in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(resource.url.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text("\(resource.fileCount.formatted()) files or links · \(resource.directoryCount.formatted()) folders measured")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if let date = resource.dates.created {
                                        Text("Created: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let date = resource.dates.accessed {
                                        Text("Filesystem access: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            HStack {
                if !entry.resources.isEmpty { Button("Show in Finder") { model.reveal(entry) } }
                if entry.category == .applications, entry.resources.first?.url.pathExtension == "app" {
                    Button("Select app & related files") { model.selectAppAndRelated(entry); dismiss() }
                        .disabled(model.busy || model.requiresRescan || !model.canSelect(entry))
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.selected.contains(entry.id) ? "Deselect" : "Select item") { model.toggle(entry); dismiss() }
                    .breezeAction(prominent: true).disabled(model.busy || model.requiresRescan || !model.canSelect(entry))
            }
        }.padding(28).frame(width: 820, height: 580).breezeAction()
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

