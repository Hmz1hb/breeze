import SwiftUI

// Personalization stays in the app; the menu widget remains a quick glance.
// Presets are starting points. Every content choice persists immediately.
struct WidgetSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Menu bar widget").font(.title3.weight(.semibold))
                    Text("Just the essentials, or every little detail. Make room for what matters to you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.widgetPreferences.presetName).font(.caption.weight(.medium))
                    .foregroundStyle(BreezeStyle.mint).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(BreezeStyle.mint.opacity(0.1), in: Capsule())
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 8) {
                        preset("Simple", subtitle: "A little peace of mind", symbol: "leaf", preferences: .simple)
                        preset("Detailed", subtitle: "For the curious", symbol: "waveform.path.ecg", preferences: .detailed)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("In the menu bar").font(.subheadline.weight(.semibold))
                        Text("Keep it compact, or pin a few live readings. Turn all readings off for just the Breeze icon.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        metricToggles(\.menuMetrics)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("At a glance").font(.subheadline.weight(.semibold))
                        Text("The headline readings at the top of the widget.")
                            .font(.caption).foregroundStyle(.secondary)
                        metricToggles(\.metrics)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Inside the widget").font(.subheadline.weight(.semibold))
                        ForEach(WidgetSection.allCases) { section in
                            Toggle(section.title, isOn: selection(section, in: \.sections))
                                .font(.system(size: 12))
                        }
                        if model.widgetPreferences.sections.contains(.history) {
                            Picker("History", selection: $model.widgetPreferences.historySeconds) {
                                Text("2 min").tag(120)
                                Text("5 min").tag(300)
                                Text("10 min").tag(600)
                            }.pickerStyle(.segmented).labelsHidden()
                                .accessibilityLabel("Widget history duration")
                        }
                    }
                    Label("Changes save automatically and update the widget right away.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Live preview").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        WidgetMenuBarLabel(model: model).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }
                    BreezeWidgetView(model: model, isPreview: true)
                    Text("Real readings from your Mac. Cooling actions are available from the menu bar.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(width: 352)
            }
        }
    }

    private func preset(_ title: String, subtitle: String, symbol: String, preferences: WidgetPreferences) -> some View {
        let selected = model.widgetPreferences == preferences
        return Button { model.widgetPreferences = preferences } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: symbol)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill") }
                }.foregroundStyle(BreezeStyle.mint)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                .breezeGlass(radius: 18, interactive: true, tint: selected ? BreezeStyle.mint.opacity(0.12) : nil)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func metricToggles(_ keyPath: WritableKeyPath<WidgetPreferences, Set<WidgetMetric>>) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(WidgetMetric.allCases) { metric in
                Toggle(isOn: selection(metric, in: keyPath)) {
                    Label(metric.title, systemImage: metric.symbol).font(.system(size: 12))
                }
            }
        }
    }

    private func selection<Value: Hashable>(_ value: Value, in keyPath: WritableKeyPath<WidgetPreferences, Set<Value>>) -> Binding<Bool> {
        Binding {
            model.widgetPreferences[keyPath: keyPath].contains(value)
        } set: { selected in
            if selected { model.widgetPreferences[keyPath: keyPath].insert(value) }
            else { model.widgetPreferences[keyPath: keyPath].remove(value) }
        }
    }
}
