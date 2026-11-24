import FanCore
import SwiftUI
import WidgetKit

// The extension is sandboxed and reads only the app group's widget.json.
// Breeze refreshes that file while it runs; WidgetKit decides when timelines reload.
@main
struct BreezeWidgets: WidgetBundle {
    var body: some Widget { BreezeStatusWidget() }
}

struct BreezeEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct BreezeProvider: TimelineProvider {
    func placeholder(in context: Context) -> BreezeEntry {
        var sample = WidgetSnapshot()
        sample.status = "System cooling"; sample.temperature = 52; sample.fanRPM = 1800; sample.fanCount = 1
        sample.cpuPercent = 12; sample.memoryPercent = 48; sample.batteryPercent = 80
        return BreezeEntry(date: .now, snapshot: sample)
    }
    func getSnapshot(in context: Context, completion: @escaping (BreezeEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : BreezeEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BreezeEntry>) -> Void) {
        let entry = BreezeEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300))))
    }
}

struct BreezeStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BreezeStatus", provider: BreezeProvider()) { entry in
            // Opaque on purpose: macOS swaps it for Liquid Glass in the Clear/Tinted widget styles;
            // a translucent fill here turns into a pale plate that hides the white text.
            BreezeWidgetEntryView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Breeze")
        .description("Temperature, fans and your Mac’s vital signs.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private let mint = Color(red: 0.22, green: 0.67, blue: 0.55)

struct BreezeWidgetEntryView: View {
    let entry: BreezeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            let stale = entry.date.timeIntervalSince(snapshot.date) > 600
            HStack(alignment: .top, spacing: 16) {
                primary(snapshot, stale: stale)
                if family == .systemMedium {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow { tile("CPU", percent(snapshot.cpuPercent), "cpu"); tile("Memory", percent(snapshot.memoryPercent), "memorychip") }
                        GridRow { tile("Battery", percent(snapshot.batteryPercent), "battery.75percent"); tile("Free", bytes(snapshot.diskFree), "internaldrive") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.opacity(stale ? 0.55 : 1)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "fanblades.fill").font(.title2).foregroundStyle(mint)
                Text("Open Breeze").font(.headline)
                Text("Readings appear here while Breeze is running.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func primary(_ snapshot: WidgetSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Breeze", systemImage: "fanblades.fill").font(.caption.weight(.semibold)).foregroundStyle(mint)
            Spacer(minLength: 0)
            Text(snapshot.temperature.map { "\(Int($0))°" } ?? "—")
                .font(.system(size: 40, weight: .medium, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(snapshot.fanCount == 0 ? "Fanless" : snapshot.fanRPM.map { "\(Int($0)) RPM" } ?? "—")
                .font(.subheadline.weight(.medium)).monospacedDigit()
            Text(stale ? "Open Breeze to update" : snapshot.status)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(snapshot.date, style: .time).font(.system(size: 9)).foregroundStyle(.tertiary)
        }.frame(maxWidth: family == .systemMedium ? 130 : .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
    private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }
}
