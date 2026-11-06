import AppKit
import FanCore
import SwiftUI

struct MacInfoView: View {
    @Bindable var model: MacInfoModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("This Mac").font(.system(size: 28, weight: .semibold, design: .rounded))
                Spacer()
                if model.loading { ProgressView().controlSize(.small).accessibilityLabel("Reading Mac information") }
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.breezeAction(size: .regular).disabled(model.loading)
                    .help("Refresh Mac information").accessibilityLabel("Refresh Mac information")
            }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 8)

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

                    group {
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
                    group {
                        row("Model identifier", lines: [model.hardware.modelIdentifier ?? "Unavailable"])
                        separator
                        row("Model year", lines: [model.identity.year ?? "Unavailable"])
                        separator
                        row("Serial number", lines: [model.hardware.serialNumber ?? "Unavailable"])
                    }
                    group {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            row("Uptime", lines: [MacInfoModel.uptime(SystemUptime.sinceBoot)])
                                .help("Time since the last restart, including sleep")
                        }
                    }
                }.padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .task { await model.refresh() }
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

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .breezeSurface(radius: 18)
    }

    private var separator: some View { Divider().padding(.horizontal, 14).opacity(0.55) }

    private func row(_ label: String, lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(lines.isEmpty ? (model.loading ? "Reading…" : "Unavailable") : lines.joined(separator: "\n"))
                .fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 40)
            .accessibilityElement(children: .combine)
    }
}
