import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var menuBar: BreezeMenuBarController?

    func installMenuBar(model: AppModel, openMainWindow: @escaping () -> Void) {
        guard menuBar == nil else { return }
        menuBar = BreezeMenuBarController(model: model, openMainWindow: openMainWindow)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.storage.cleanup.revokeAssistantSnapshot()
        menuBar?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.quit() }
        return .terminateLater
    }
}

@main
struct BreezeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Breeze", id: "main") {
            Dashboard(model: model)
                .modifier(BreezeMenuBarSetup(model: model, delegate: delegate))
                .task {
                    delegate.model = model; model.start()
                    if CommandLine.arguments.contains("--statistics") { model.page = .statistics }
                    if CommandLine.arguments.contains("--processes") { model.page = .statistics; model.activity.tab = .processes }
                    if CommandLine.arguments.contains("--network") { model.page = .network }
                    if CommandLine.arguments.contains("--this-mac") { model.page = .mac }
                    if CommandLine.arguments.contains("--battery") { model.page = .battery }
                    if let index = CommandLine.arguments.firstIndex(of: "--scan-folder"),
                       CommandLine.arguments.indices.contains(index + 1), model.storage.scan == nil, !model.storage.busy {
                        model.page = .storage
                        model.storage.start(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 800)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}

private struct BreezeMenuBarSetup: ViewModifier {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.installMenuBar(model: model) { [openWindow] in openWindow(id: "main") }
        }
    }
}

