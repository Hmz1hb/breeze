import AppKit
import FanCore
import SwiftUI

struct ActivityProcessesView: View {
    @Bindable var model: ActivityModel
    @State private var search = ""
    @State private var mineOnly = false
    @State private var selection: ActivityProcess.ID?
    @State private var sortOrder = [KeyPathComparator(\ActivityProcess.cpuSort, order: .reverse)]

    private var filtered: [ActivityProcess] {
        model.processes.filter {
            (!mineOnly || $0.uid == getuid()) &&
            (search.isEmpty || $0.name.localizedStandardContains(search) || $0.user.localizedStandardContains(search) || String($0.pid).contains(search))
        }.sorted(using: sortOrder)
    }
    private var selected: ActivityProcess? { model.processes.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search processes, users, or PID", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear process search")
                    }
                }.padding(10).breezeSurface(radius: 12)
                Toggle("My processes", isOn: $mineOnly).toggleStyle(.checkbox)
            }
            if let error = model.processError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name) { process in
                    HStack(spacing: 8) {
                        Image(systemName: "app.dashed").foregroundStyle(.secondary)
                        Text(process.name).lineLimit(1)
                    }.help(process.name)
                }.width(min: 150, ideal: 220)
                TableColumn("% CPU", value: \.cpuSort) { process in
                    Text(process.cpu.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }.width(65)
                TableColumn("Memory", value: \.memorySort) { process in
                    Text(process.memory.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "—")
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }.width(85)
                TableColumn("Threads", value: \.threadsSort) { process in
                    Text(process.threads.map(String.init) ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }.width(60)
                TableColumn("PID", value: \.pid) { process in Text(String(process.pid)).monospacedDigit() }.width(60)
                TableColumn("User", value: \.user).width(min: 70, ideal: 90)
                TableColumn("CPU time", value: \.timeSort) { process in
                    Text(process.cpuTime.map { String(format: "%d:%05.2f", Int($0) / 60, $0.truncatingRemainder(dividingBy: 60)) } ?? "—").monospacedDigit()
                }.width(85)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .breezeSurface(radius: 18)
            .overlay {
                if model.processUpdated == nil && model.processError == nil {
                    ProgressView("Reading processes…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else if filtered.isEmpty {
                    ContentUnavailableView("No matching processes", systemImage: "magnifyingglass", description: Text("Try another name, user, or process ID."))
                }
            }
            .frame(minHeight: 330)
            HStack {
                Text("\(filtered.count) of \(model.processes.count) processes")
                Spacer()
                if let updated = model.processUpdated { Text("Sampled \(updated, style: .time)").monospacedDigit() }
            }.font(.caption).foregroundStyle(.secondary)
            if let selected {
                HStack(spacing: 12) {
                    Image(systemName: "app").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.name).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                        Text("PID \(selected.pid) · \(selected.user)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Open Activity Monitor", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }.help("Open Activity Monitor to inspect or manage processes")
                }.padding(14).breezeSurface(radius: 18)
            }
            Text("100% CPU equals one fully used core. Memory shows physical footprint, or resident size when footprint is unavailable. A dash means a restricted reading or CPU warm-up. macOS may hide protected processes.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
