import AppKit
import FanCore
import SwiftUI

struct MacInfoView: View {
    @Bindable var model: MacInfoModel
    @State private var scrolled = false

    var body: some View {
        VStack(spacing: 0) {
            BreezePageHeader("This Mac", subtitle: "", scrolled: scrolled) {
                // Reserved slot: the spinner only appears after 0.3 s and never shifts the button.
                ZStack { if model.loading { BreezeDelayedProgress("Reading Mac information").controlSize(.small).labelsHidden() } }
                    .frame(width: 16, height: 16)
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.breezeAction(size: .regular).disabled(model.loading)
                    .help("Refresh Mac information").accessibilityLabel("Refresh Mac information")
            }

            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 5) {
                        Group {
                            if let image = model.image {
                                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            } else {
                                Image(systemName: "desktopcomputer").resizable().scaledToFit()
                                    .foregroundStyle(.tertiary).padding(24)
                            }
                        }.frame(width: 156, height: 108).accessibilityHidden(true)
                        Text(model.loaded ? model.title : "Your Mac")
                            .font(.system(size: 19, weight: .semibold)).multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Text(model.operatingSystem).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.bottom, 8)

                    group(0) {
                        row("Processor", lines: model.hardware.processorLines)
                        separator
                        row("Memory", lines: [model.hardware.memory ?? "Unavailable"])
                        separator
                        row("Graphics", lines: model.hardware.graphics)
                        separator
                        row("Disks", lines: model.hardware.disks)
                        separator
                        row("Display", lines: model.displays)
                    }
                    group(1) {
                        row("Model identifier", lines: [model.hardware.modelIdentifier ?? "Unavailable"])
                        separator
                        row("Model year", lines: [model.identity.year ?? "Unavailable"])
                        separator
                        row("Serial number", lines: [model.hardware.serialNumber ?? "Unavailable"])
                    }
                    group(2) {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            row("Uptime", lines: [MacInfoModel.uptime(SystemUptime.sinceBoot)])
                                .help("Time since the last restart, including sleep")
                        }
                    }
                }.padding(.horizontal, BreezeStyle.pagePadding).padding(.bottom, 28).breezeScrollEdge($scrolled)
                    .breezeAnimation(.settle, value: model.loaded)
            }
        }
        .task { if !model.loaded { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.refreshDisplays()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private func group<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .breezeSurface(radius: 18)
            .breezeReveal(index, key: "mac")
    }

    private var separator: some View { Divider().padding(.horizontal, 14).opacity(0.55) }

    private func row(_ label: String, lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(lines.isEmpty ? (model.loading ? "Reading…" : "Unavailable") : lines.joined(separator: "\n"))
                .fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 40)
            .accessibilityElement(children: .combine)
    }
}
