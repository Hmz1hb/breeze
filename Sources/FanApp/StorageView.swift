import AppKit
import StorageCore
import QuickLookUI
import SwiftUI

private let storageMint = Color(red: 0.22, green: 0.67, blue: 0.55)

private extension FileCategory {
    var color: Color {
        switch self {
        case .video: .indigo
        case .images: .pink
        case .audio: .orange
        case .documents: .blue
        case .archives: .teal
        case .other: .gray
        }
    }
}

private func storageSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// Intent: locate space, understand the evidence, then decide. Native SF typography,
// four-point spacing, quiet surface shifts and mint actions keep the explorer calm.
// Category colors carry file-type meaning; paths stay visible through review.
struct StorageView: View {
    @Bindable var model: StorageModel
    @State private var showingMap = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                Picker("Storage workspace", selection: $model.workspace) {
                    ForEach(StorageModel.Workspace.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 450)
                    .disabled(model.busy || model.cleanup.busy)
                Spacer()
            }.padding(.horizontal, 28).padding(.bottom, 20)
            if model.workspace == .overview {
                StorageOverviewView(monitor: model.monitor)
            } else if model.workspace == .cleanup {
                StorageCleanupView(model: model.cleanup)
            } else {
            if let message = model.message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(storageMint)
                    Text(message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }.padding(12).background(storageMint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            if model.scanning {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.progress).font(.subheadline.weight(.medium))
                        Text("\(model.fileCount.formatted()) files found · your files stay on this Mac")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { model.cancel() }
                }.padding(16).breezeSurface(radius: 18)
                    .padding(.horizontal, 28).padding(.bottom, 16)
            }
            if let scan = model.scan {
                results(scan).disabled(model.cleaning)
            } else {
                emptyState
            }
            footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $model.showingReview) { StorageReviewView(model: model) }
        .sheet(item: $model.inspected) { file in
            StorageFilePreview(file: file, selection: Binding(
                get: { model.selection.contains(file.id) },
                set: { _ in model.toggle(file) }
            ))
        }
        .tint(storageMint)
        .task { await model.monitor.run() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let scan = model.scan, model.workspace == .files {
                Button { model.start(scan.root) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan this folder").accessibilityLabel("Rescan folder").disabled(model.busy)
            }
            if model.workspace != .cleanup {
                Button("Choose folder", systemImage: "folder.badge.plus") { model.chooseFolder() }
                    .breezeAction(prominent: true).disabled(model.busy || model.cleanup.busy)
            }
        }.padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 20)
    }

    private var subtitle: String {
        switch model.workspace {
        case .overview: "A closer look at the drives behind your day."
        case .files: "See the space. Keep what matters."
        case .cleanup: "Know what it is. Decide what stays."
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.split.2x2").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(storageMint)
            Text(model.scanning ? "Finding a little breathing room…" : "What’s taking up your space?")
                .font(.system(size: 24, weight: .medium, design: .rounded))
            Text("Start with Downloads, Documents, or another personal folder.\nExplore a space map, identical copies, and files worth reviewing.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            if !model.scanning {
                Button("Choose a folder to scan") { model.chooseFolder() }.breezeAction(prominent: true)
            }
            HStack(spacing: 24) {
                Label("Local scanning", systemImage: "lock")
                Label("You choose what goes", systemImage: "checkmark.circle")
                Label("Move to Trash", systemImage: "trash")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            Spacer()
        }.frame(maxWidth: .infinity).padding(28)
    }

    private func results(_ scan: StorageScan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(storageSize(scan.bytes)).font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                    Text("\(scan.files.count.formatted()) scanned files").font(.caption).foregroundStyle(.secondary)
                }
                Divider().frame(height: 40)
                summaryValue(storageSize(scan.extraDuplicateBytes), label: "in extra duplicate copies")
                summaryValue(model.suggestedFiles.count.formatted(), label: "files worth reviewing")
                Spacer(minLength: 0)
            }
            Picker("Storage view", selection: $model.tab) {
                ForEach(StorageModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: model.tab) { model.visibleRows = 100 }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if scan.reachedLimit || scan.unreadable > 0 || scan.duplicateReadFailures > 0 {
                        Label("Partial results: \(scan.unreadable) unreadable locations; \(scan.duplicateReadFailures) duplicate checks unavailable.\(scan.reachedLimit ? " The 250,000-file limit was reached; scan a smaller folder." : "")", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    switch model.tab {
                    case .map: mapContents(scan)
                    case .duplicates: duplicateContents(scan)
                    case .suggestions: suggestionContents
                    }
                    Text("Scope: \(scan.root.path)\nHidden items, system data, libraries, app bundles, links and iCloud-managed files are excluded. \(scan.skipped) additional items skipped. Sizes describe scanned files, not the entire disk. APFS copies can share disk blocks, so cleanup totals are estimates.")
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }.padding(.bottom, 20)
            }
        }.padding(.horizontal, 28).frame(maxHeight: .infinity)
    }

    private func summaryValue(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func breadcrumbs(_ scan: StorageScan) -> [URL] {
        var folders = [model.focusedFolder ?? scan.root]
        while let first = folders.first, first.path != scan.root.path, first.path != "/" {
            folders.insert(first.deletingLastPathComponent(), at: 0)
        }
        return folders
    }

    @ViewBuilder private func mapContents(_ scan: StorageScan) -> some View {
        let folderBytes = model.nodes.reduce(0) { $0 + $1.bytes }
        HStack(spacing: 10) {
            Button { model.focus((model.focusedFolder ?? scan.root).deletingLastPathComponent()) } label: {
                Image(systemName: "arrow.up")
            }.disabled(model.focusedFolder?.path == scan.root.path)
                .help("Open parent folder").accessibilityLabel("Open parent folder")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(breadcrumbs(scan), id: \.path) { folder in
                        if folder.path != scan.root.path {
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Button(folder.lastPathComponent.isEmpty ? "Scan root" : folder.lastPathComponent) { model.focus(folder) }
                            .buttonStyle(.plain)
                            .foregroundStyle(folder == model.focusedFolder ? Color.primary : storageMint)
                            .help(folder.path)
                    }
                }.font(.subheadline)
            }.scrollIndicators(.hidden)
        }.padding(12).breezeSurface(radius: 16)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(storageMint)
            VStack(alignment: .leading, spacing: 4) {
                Text((model.focusedFolder ?? scan.root).lastPathComponent).font(.title3.weight(.semibold))
                Text("\(model.nodes.count.formatted()) \(model.nodes.count == 1 ? "item" : "items") · \(storageSize(folderBytes)) · largest first")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingMap.toggle() } label: {
                Label(showingMap ? "Hide map" : "Show space map", systemImage: "square.split.2x2")
            }.controlSize(.small)
        }.padding(.vertical, 4)

        if model.nodes.isEmpty {
            inlineEmpty("This folder is empty", detail: "No scanned files remain here. Use the path above to keep exploring.", symbol: "folder")
        } else {
            if showingMap {
                VStack(alignment: .leading, spacing: 10) {
                    StorageMapView(nodes: model.nodes, action: model.inspect).frame(height: 180)
                    HStack(spacing: 12) {
                        ForEach(FileCategory.allCases, id: \.self) { category in
                            HStack(spacing: 4) {
                                Circle().fill(category.color).frame(width: 6, height: 6)
                                Text(category.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Text("Size = area").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Name").padding(.leading, 32)
                    Spacer()
                    Text("Size / share of folder").padding(.trailing, 32)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(model.nodes.prefix(model.visibleRows)) { node in
                        browserRow(node, folderBytes: folderBytes)
                    }
                    moreButton(total: model.nodes.count)
                }
            }.breezeSurface(radius: 18)
        }
    }

    private func browserRow(_ node: StorageNode, folderBytes: Int64) -> some View {
        let fraction = folderBytes > 0 ? Double(node.bytes) / Double(folderBytes) : 0
        return HStack(spacing: 12) {
            if let file = model.file(node.id) { selectionToggle(file).frame(width: 20) }
            else { Color.clear.frame(width: 20, height: 20) }
            Button { model.inspect(node) } label: {
                HStack(spacing: 12) {
                    StorageThumbnail(url: node.url, isDirectory: node.isDirectory)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(node.url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(node.isDirectory ? "\(node.count.formatted()) \(node.count == 1 ? "file" : "files") · open folder" : "\(node.category.rawValue) · click to preview")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(storageSize(node.bytes)).monospacedDigit()
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                        }.font(.caption)
                        GeometryReader { geometry in
                            Capsule().fill(.quaternary)
                            Capsule().fill(node.isDirectory ? storageMint : node.category.color)
                                .frame(width: max(fraction > 0 ? 2 : 0, geometry.size.width * fraction))
                        }.frame(width: 120, height: 3)
                    }.frame(width: 158, alignment: .trailing)
                    Image(systemName: node.isDirectory ? "chevron.right" : "eye")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 20)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(node.isDirectory ? "Open \(node.url.lastPathComponent)" : "Preview \(node.url.lastPathComponent)")
        }.padding(.horizontal, 14).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider().opacity(0.5).padding(.leading, 46) }
    }

    @ViewBuilder private func duplicateContents(_ scan: StorageScan) -> some View {
        Text("Identical file contents, checked with SHA-256. Names and metadata may differ. Choose copies to remove; at least one copy must stay.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !scan.duplicatesComplete {
            inlineEmpty(model.scanning ? "Checking duplicate contents…" : "Duplicate checks are incomplete",
                        detail: model.scanning ? "You can browse and preview files while this finishes." : "Rescan this folder to finish checking before cleanup.", symbol: "doc.on.doc")
        } else if scan.duplicates.isEmpty {
            inlineEmpty("No exact duplicates found", detail: "No matching non-empty file contents were found in the scanned files.", symbol: "doc.on.doc")
        } else {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(scan.duplicates.prefix(model.visibleRows)) { group in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("\(group.files.count) identical copies").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(storageSize(group.extraBytes)) in extra copies").font(.caption).foregroundStyle(.secondary)
                        }.padding(.bottom, 8)
                        ForEach(group.files) { file in fileRow(file) }
                    }
                }
                moreButton(total: scan.duplicates.count)
            }
        }
    }

    private var suggestionContents: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A starting point for your review. An old modification date does not mean a file is unused. Breeze does not track which apps or files you open.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.suggestedFiles.isEmpty {
                inlineEmpty("Nothing flagged for review", detail: "No old installers or large files met the review criteria in this folder.", symbol: "checkmark.circle")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.suggestedFiles.prefix(model.visibleRows)) { file in
                        fileRow(file, reason: file.suggestion(now: model.scan?.finished ?? .now))
                    }
                    moreButton(total: model.suggestedFiles.count)
                }
            }
        }
    }

    private func selectionToggle(_ file: StorageFile) -> some View {
        Toggle("Select \(file.url.lastPathComponent)", isOn: Binding(
            get: { model.selection.contains(file.id) }, set: { _ in model.toggle(file) }
        )).labelsHidden().toggleStyle(.checkbox).disabled(model.busy || model.scan?.duplicatesComplete != true)
    }

    private func fileRow(_ file: StorageFile, reason: String? = nil) -> some View {
        HStack(spacing: 12) {
            selectionToggle(file)
            Button { model.inspected = file } label: {
                HStack(spacing: 12) {
                    StorageThumbnail(url: file.url)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.url.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                        Text(file.url.deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(file.url.path)
                        if let reason { Text(reason).font(.caption2).foregroundStyle(storageMint) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Preview \(file.url.lastPathComponent)")
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(storageSize(file.bytes)).font(.subheadline).monospacedDigit()
                Text(file.modified, format: .dateTime.year().month().day()).font(.caption2).foregroundStyle(.secondary)
            }
            Button { model.inspected = file } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless).help("Preview file").accessibilityLabel("Preview \(file.url.lastPathComponent)")
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal \(file.url.lastPathComponent) in Finder")
        }.padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func inlineEmpty(_ title: String, detail: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail)).frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    @ViewBuilder private func moreButton(total: Int) -> some View {
        if total > model.visibleRows {
            Button("Show more (\((total - model.visibleRows).formatted()) remaining)") { model.visibleRows += 100 }.padding(.vertical, 12)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if model.cleaning { ProgressView().controlSize(.small); Text("Moving reviewed files to Trash…").font(.caption) }
                else if model.selection.isEmpty {
                    Label("Nothing selected. Your files stay put until you review.", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(model.selection.count) selected · \(storageSize(model.selectedBytes))").font(.subheadline).monospacedDigit()
                    Button("Clear selection") { model.selection = [] }.disabled(model.busy)
                }
                Spacer()
                Button("Review selected", systemImage: "checklist") { model.prepareReview() }
                    .breezeAction(prominent: true).disabled(model.selection.isEmpty || model.busy)
            }.padding(.horizontal, 28).frame(height: 64)
        }
    }

}

/// Quick Look generates bounded thumbnails; unsupported types retain their Finder icon.
private struct StorageThumbnail: View {
    let url: URL
    var isDirectory = false
    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if isDirectory {
                Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(storageMint).padding(7)
            } else {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary).padding(9)
                }
            }
        }.frame(width: 44, height: 44)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
            .task(id: url) {
                thumbnail = nil
                guard !isDirectory else { return }
                let result = await StorageThumbnailLoader.shared.image(for: url, scale: displayScale)
                if !Task.isCancelled { thumbnail = result }
            }
    }
}

struct StorageQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

private struct StorageFilePreview: View {
    let file: StorageFile
    var selection: Binding<Bool>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StorageThumbnail(url: file.url)
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.url.lastPathComponent).font(.title3.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    Text("\(storageSize(file.bytes)) · modified \(file.modified.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            StorageContentPreview(file: file).frame(maxWidth: .infinity).frame(height: 380)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10)).clipped()
            Text(file.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                Spacer()
                if let selection { Toggle("Select for Trash", isOn: selection).toggleStyle(.checkbox) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 680).breezeAction()
    }
}

private struct StorageReviewView: View {
    @Bindable var model: StorageModel
    @State private var previewID: String?
    private var previewFile: StorageFile? { model.reviewFiles.first { $0.id == previewID } ?? model.reviewFiles.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review before moving to Trash").font(.title2.weight(.semibold))
            Text("\(model.reviewFiles.count) \(model.reviewFiles.count == 1 ? "file" : "files") · \(storageSize(model.reviewFiles.reduce(0) { $0 + $1.bytes })) · select a file to preview")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.reviewFiles) { file in
                            Button { previewID = file.id } label: {
                                HStack(spacing: 10) {
                                    StorageThumbnail(url: file.url)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.url.lastPathComponent).font(.subheadline.weight(.medium))
                                            .lineLimit(2).truncationMode(.middle)
                                        Text(storageSize(file.bytes)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "eye").font(.caption).foregroundStyle(.secondary)
                                }.padding(10).contentShape(Rectangle())
                                    .background(previewFile?.id == file.id ? storageMint.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(8)
                }.frame(width: 300)
                Divider()
                if let file = previewFile {
                    VStack(alignment: .leading, spacing: 12) {
                        StorageContentPreview(file: file).frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(file.url.lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                        Text(file.url.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text("Modified \(file.modified.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                .controlSize(.small)
                        }
                    }.padding(16).frame(maxWidth: .infinity)
                }
            }.frame(height: 380).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            Text("You can restore these files from Trash in Finder. Space is released when Trash is emptied; shared APFS blocks may reduce the space recovered.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.showingReview = false }.keyboardShortcut(.cancelAction)
                Button("Move \(model.reviewFiles.count) \(model.reviewFiles.count == 1 ? "file" : "files") to Trash", role: .destructive) { model.trashReviewed() }
                    .breezeAction(prominent: true)
            }
        }.padding(24).frame(width: 860).breezeAction()
    }
}

private struct StorageMapView: View {
    let nodes: [StorageNode]
    let action: (StorageNode) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let shown = Array(nodes.prefix(100))
            let remaining = nodes.dropFirst(100).reduce(0) { $0 + $1.bytes }
            let weights = shown.map(\.bytes) + (remaining > 0 ? [remaining] : [])
            let tiles = StorageTreemap.layout(weights: weights, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.index) { tile in
                    if tile.index < shown.count {
                        let node = shown[tile.index]
                        Button { action(node) } label: {
                            tileLabel(node.url.lastPathComponent, detail: storageSize(node.bytes),
                                      symbol: node.isDirectory ? "folder" : "doc", rect: tile.rect)
                                .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                                .background(node.category.color.opacity(colorScheme == .dark ? 0.32 : 0.18), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(node.category.color.opacity(0.25)))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).offset(x: tile.rect.minX, y: tile.rect.minY)
                            .help("\(node.url.path) · \(storageSize(node.bytes))")
                            .accessibilityLabel("\(node.url.lastPathComponent), \(storageSize(node.bytes))\(node.isDirectory ? ", open folder" : ", show file")")
                    } else {
                        tileLabel("\(nodes.count - 100) more items", detail: "See list below", symbol: "ellipsis", rect: tile.rect)
                            .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .offset(x: tile.rect.minX, y: tile.rect.minY)
                    }
                }
            }
        }
    }

    private func tileLabel(_ title: String, detail: String, symbol: String, rect: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if rect.width > 80, rect.height > 52 {
                Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle)
                if rect.height > 90 { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }.padding(min(12, max(0, rect.width / 8)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
    }
}
