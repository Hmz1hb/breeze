import AppKit
import Observation
import SwiftUI

// Keep the native status button for highlighting, accessibility, and clicks,
// but supply its complete image so both rows of every selected reading survive.
@MainActor
final class BreezeMenuBarController: NSObject {
    private let model: AppModel
    private let openMainWindow: () -> Void
    private let statusItem: NSStatusItem
    private var panel: WidgetPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var notifications: [NSObjectProtocol] = []
    private var renderedReadings: [WidgetMenuBarReading]?
    private var renderedScale: CGFloat = 0
    private var readingsImage: CGImage?
    private var fanImage: CGImage?
    private var labelSize = CGSize.zero
    private var animationTimer: Timer?
    private var motionObserver: NSObjectProtocol?
    private var fanAngle = 0.0
    private var fanRevolutionsPerSecond = 0.0
    private var lastAnimationTime: TimeInterval?
    private var pendingHeight: CGFloat?
    private var resizeScheduled = false
    private var stopped = false

    init(model: AppModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.setAccessibilityLabel("Breeze")
            button.setAccessibilityHelp("Show live readings and cooling controls")
        }
        observeReadings()

        let center = NotificationCenter.default
        notifications.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dismissPanel()
                self.renderLabel(WidgetMenuBarReading.current(model: self.model))
            }
        })
        notifications.append(center.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification, object: statusItem.button?.window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.renderLabel(WidgetMenuBarReading.current(model: self.model))
            }
        })
        notifications.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissPanel() }
        })
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateFanAnimation(rpm: self.currentFanRPM)
            }
        }
    }

    private var currentFanRPM: Double {
        guard !model.sleeping, model.readError == nil else { return 0 }
        return model.snapshot?.fans.map(\.current).filter { $0.isFinite && $0 > 0 }.max() ?? 0
    }

    private func observeReadings() {
        guard !stopped else { return }
        let (readings, rpm) = withObservationTracking {
            (WidgetMenuBarReading.current(model: model), currentFanRPM)
        } onChange: { [weak self] in
            // Observation fires before mutation; read and re-arm on the next turn.
            Task { @MainActor in self?.observeReadings() }
        }
        renderLabel(readings)
        updateFanAnimation(rpm: rpm)
    }

    private func renderLabel(_ readings: [WidgetMenuBarReading]) {
        guard !stopped, let button = statusItem.button else { return }
        let scale = button.window?.backingScaleFactor ?? 2
        guard readings != renderedReadings || scale != renderedScale else { return }
        let renderer = ImageRenderer(content: WidgetMenuBarContent(readings: readings, showsFanIcon: false)
            .environment(\.colorScheme, .light)
            .foregroundStyle(.black))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return }
        if fanImage == nil || scale != renderedScale {
            let iconRenderer = ImageRenderer(content: WidgetMenuBarFanIcon()
                .frame(height: 22)
                .environment(\.colorScheme, .light)
                .foregroundStyle(.black))
            iconRenderer.scale = scale
            guard let icon = iconRenderer.cgImage else { return }
            fanImage = icon
        }
        readingsImage = image
        labelSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let length = ceil(labelSize.width) + 16
        let lengthChanged = abs(statusItem.length - length) > 0.5
        if lengthChanged { statusItem.length = length }
        drawLabel()
        let summary = readings.map { "\($0.metric.title): \($0.value)" }.joined(separator: ", ")
        button.toolTip = summary.isEmpty ? "Breeze" : "Breeze · \(summary)"
        button.setAccessibilityValue(summary)
        renderedReadings = readings
        renderedScale = scale
        if lengthChanged, panel != nil { positionPanel() }
    }

    private func updateFanAnimation(rpm: Double) {
        guard !stopped else { return }
        advanceFanAngle()
        // Slow physical RPM down 50× so individual blades remain readable.
        // Cap at three visual revolutions per second to avoid strobing at 30 fps.
        fanRevolutionsPerSecond = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0 : min(rpm / 3000, 3)
        guard fanRevolutionsPerSecond > 0 else {
            animationTimer?.invalidate()
            animationTimer = nil
            lastAnimationTime = nil
            drawLabel()
            return
        }
        guard animationTimer == nil else { return }
        lastAnimationTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            // This timer is installed only on the main run loop.
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.advanceFanAngle()
                self.drawLabel()
            }
        }
        timer.tolerance = timer.timeInterval * 0.1
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceFanAngle() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastAnimationTime {
            fanAngle = (fanAngle + (now - lastAnimationTime) * fanRevolutionsPerSecond * 2 * .pi)
                .truncatingRemainder(dividingBy: 2 * .pi)
        }
        lastAnimationTime = now
    }

    private func drawLabel() {
        guard let readingsImage, let fanImage, let button = statusItem.button else { return }
        let size = labelSize
        let angle = fanAngle
        // Compose cached artwork instead of laying out SwiftUI on every frame.
        // Keep a template image so AppKit still supplies menu bar/highlight colors.
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.draw(readingsImage, in: rect)
            context.saveGState()
            context.translateBy(x: rect.minX + 8, y: rect.midY)
            context.rotate(by: CGFloat(-angle))
            context.draw(fanImage, in: CGRect(x: -8, y: -11, width: 16, height: 22))
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        button.image = image
    }

    @objc private func togglePanel() {
        if panel != nil { dismissPanel() }
        else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button, let screen = button.window?.screen else { return }
        let panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: BreezeWidgetView.width, height: 540),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.dismissPanel() }
        panel.setAccessibilityLabel("Breeze live readings")
        self.panel = panel

        let widget = BreezeWidgetView(
            model: model,
            maximumContentHeight: max(120, min(440, screen.visibleFrame.height - 180)),
            openMainWindow: { [weak self] page in
                guard let self else { return }
                self.dismissPanel()
                self.model.page = page
                self.openMainWindow()
                NSApp.activate(ignoringOtherApps: true)
            },
            onHeightChange: { [weak self, weak panel] height in
                guard let self, let panel, self.panel === panel else { return }
                self.scheduleResize(height)
            }
        )
        let hostingView = NSHostingView(rootView: widget)
        hostingView.sizingOptions = [.intrinsicContentSize]
        // Match the hosting layer to the glass shell, keeping the corners
        // transparent and the AppKit shadow on the same rounded outline.
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = BreezeWidgetView.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        panel.setContentSize(NSSize(width: BreezeWidgetView.width, height: ceil(hostingView.fittingSize.height)))
        positionPanel()
        hostingView.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installDismissalMonitors()
    }

    private func scheduleResize(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        pendingHeight = ceil(height)
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard let panel = self.panel, let height = self.pendingHeight else { return }
            self.pendingHeight = nil
            if abs(panel.frame.height - height) > 0.5 {
                panel.setContentSize(NSSize(width: BreezeWidgetView.width, height: height))
                panel.contentView?.layoutSubtreeIfNeeded()
                self.positionPanel()
                panel.invalidateShadow()
            }
        }
    }

    private func positionPanel() {
        guard let panel, let button = statusItem.button, let window = button.window,
              let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width)
        let top = min(anchor.minY - 6, screen.visibleFrame.maxY - 6)
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, top - panel.frame.height)))
    }

    private func installDismissalMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismissPanel(); return nil }
            } else if event.window !== self.panel && event.window !== self.statusItem.button?.window {
                self.dismissPanel()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor in self?.dismissPanel() }
        }
    }

    private func dismissPanel() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        pendingHeight = nil
        statusItem.button?.highlight(false)
    }

    func stop() {
        stopped = true
        animationTimer?.invalidate()
        animationTimer = nil
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        motionObserver = nil
        dismissPanel()
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
        notifications.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

private final class WidgetPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
