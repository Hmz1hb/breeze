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
    /// With "Separate menu bar items", every reading after the first gets its own item.
    private var extraItems: [WidgetMetric: NSStatusItem] = [:]
    /// The item whose click opened the panel; the panel anchors under it.
    private weak var anchoredButton: NSStatusBarButton?
    private var panelButton: NSStatusBarButton? { anchoredButton ?? statusItem.button }
    private var renderedSeparate = false
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
    private var workspaceNotifications: [NSObjectProtocol] = []
    private var screensAsleep = false
    private var systemAsleep = false
    private var fanAngle = 0.0
    private var fanRevolutionsPerSecond = 0.0
    private var lastAnimationTime: TimeInterval?
    private var pendingHeight: CGFloat?
    private var resizeScheduled = false
    private var stopped = false
    // The open animation owns the frame; resizes wait for it (see `applyPendingResize`).
    private var opening = false
    private var closing = false
    private static let openDuration = 0.15
    private static let closeDuration = 0.10
    private static let reducedDuration = 0.12
    private static let settleDistance: CGFloat = 4

    init(model: AppModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
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
                self.dismissPanel(animated: false)
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
        observeMotionGates()
    }

    // Each gate only triggers a re-evaluation; `motionAllowed` reads the live state.
    private func observeMotionGates() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceNotifications = [
            gate(NSWorkspace.screensDidSleepNotification, center: workspace) { $0.screensAsleep = true },
            gate(NSWorkspace.screensDidWakeNotification, center: workspace) { $0.screensAsleep = false },
            gate(NSWorkspace.willSleepNotification, center: workspace) { $0.systemAsleep = true },
            gate(NSWorkspace.didWakeNotification, center: workspace) { $0.systemAsleep = false },
        ]
        notifications.append(gate(NSWindow.didChangeOcclusionStateNotification, center: .default,
                                  object: statusItem.button?.window) { _ in })
        notifications.append(gate(.NSProcessInfoPowerStateDidChange, center: .default) { _ in })
    }

    private func gate(_ name: Notification.Name, center: NotificationCenter, object: Any? = nil,
                      _ update: @escaping @MainActor (BreezeMenuBarController) -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                update(self)
                self.updateFanAnimation(rpm: self.currentFanRPM)
            }
        }
    }

    private var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !screensAsleep && !systemAsleep
            && (statusItem.button?.window?.occlusionState.contains(.visible) ?? true)
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
        let separate = model.widgetPreferences.separateItems == true
        guard readings != renderedReadings || scale != renderedScale || separate != renderedSeparate else { return }
        syncExtraItems(separate ? Array(readings.dropFirst()) : [], scale: scale)
        renderedSeparate = separate
        let allReadings = readings
        let readings = separate ? Array(readings.prefix(1)) : readings
        let renderer = ImageRenderer(content: WidgetMenuBarContent(readings: readings, showsFanIcon: false, titled: separate)
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
        renderedReadings = allReadings
        renderedScale = scale
        if lengthChanged, panel != nil { positionPanel() }
    }

    private func syncExtraItems(_ readings: [WidgetMenuBarReading], scale: CGFloat) {
        let wanted = Set(readings.map(\.metric))
        for (metric, item) in extraItems where !wanted.contains(metric) {
            if anchoredButton === item.button { dismissPanel(animated: false) }
            NSStatusBar.system.removeStatusItem(item)
            extraItems[metric] = nil
        }
        for reading in readings {
            let item = extraItems[reading.metric] ?? {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                // macOS remembers each item's ⌘-drag position by this name.
                item.autosaveName = "breeze.\(reading.metric.rawValue)"
                item.button?.target = self
                item.button?.action = #selector(togglePanel(_:))
                item.button?.imagePosition = .imageOnly
                item.button?.imageScaling = .scaleNone
                item.button?.setAccessibilityLabel("Breeze \(reading.metric.title)")
                extraItems[reading.metric] = item
                return item
            }()
            let renderer = ImageRenderer(content: WidgetMenuBarContent(readings: [reading], reservesFanIcon: false, titled: true)
                .padding(.horizontal, 2)
                .environment(\.colorScheme, .light)
                .foregroundStyle(.black))
            renderer.scale = scale
            guard let cgImage = renderer.cgImage else { continue }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
            image.isTemplate = true
            item.button?.image = image
            let summary = "\(reading.metric.title): \([reading.value, reading.secondary].compactMap { $0 }.joined(separator: " "))"
            item.button?.toolTip = "Breeze · \(summary)"
            item.button?.setAccessibilityValue(summary)
        }
    }

    private func updateFanAnimation(rpm: Double) {
        guard !stopped else { return }
        advanceFanAngle()
        // Slow physical RPM down 50× so individual blades remain readable.
        // Cap at three visual revolutions per second to avoid strobing at 30 fps.
        fanRevolutionsPerSecond = motionAllowed ? min(rpm / 3000, 3) : 0
        guard fanRevolutionsPerSecond > 0 else {
            animationTimer?.invalidate()
            animationTimer = nil
            lastAnimationTime = nil
            drawLabel()
            return
        }
        // 30 fps from one visual revolution per second, 15 fps below.
        let interval = fanRevolutionsPerSecond >= 1 ? 1.0 / 30 : 1.0 / 15
        if let animationTimer, abs(animationTimer.timeInterval - interval) < 0.001 { return }
        animationTimer?.invalidate()
        lastAnimationTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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

    @objc private func togglePanel(_ sender: Any?) {
        if closing {
            // A click during the fade finishes teardown at once and reopens.
            finishTeardown()
            showPanel(from: sender as? NSStatusBarButton)
        } else if panel != nil { dismissPanel() }
        else { showPanel(from: sender as? NSStatusBarButton) }
    }

    private func showPanel(from sender: NSStatusBarButton?) {
        anchoredButton = sender
        guard let button = panelButton, let screen = button.window?.screen else { return }
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
        let final = panel.frame
        let reduceMotion = BreezeMotion.systemReduceMotion
        panel.alphaValue = 0
        if !reduceMotion { panel.setFrameOrigin(NSPoint(x: final.minX, y: final.minY + Self.settleDistance)) }
        opening = true
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installDismissalMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? Self.reducedDuration : Self.openDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(final, display: true) }
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel, self.panel === panel, self.opening else { return }
                self.opening = false
                self.positionPanel()
                self.applyPendingResize()
            }
        })
    }

    private func scheduleResize(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        pendingHeight = ceil(height)
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.applyPendingResize()
        }
    }

    private func applyPendingResize() {
        guard !opening, !closing, let panel, let height = pendingHeight else { return }
        pendingHeight = nil
        if abs(panel.frame.height - height) > 0.5 {
            panel.setContentSize(NSSize(width: BreezeWidgetView.width, height: height))
            panel.contentView?.layoutSubtreeIfNeeded()
            positionPanel()
            panel.invalidateShadow()
        }
    }

    private func positionPanel() {
        guard !opening, let panel, let button = panelButton, let window = button.window,
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
            } else if event.window !== self.panel && event.window !== self.panelButton?.window {
                self.dismissPanel()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor in self?.dismissPanel() }
        }
    }

    private func dismissPanel(animated: Bool = true) {
        guard let panel else { return }
        if closing {
            if !animated { finishTeardown() }
            return
        }
        removeDismissalMonitors()
        opening = false
        guard animated, panel.isVisible else { finishTeardown(); return }
        closing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = BreezeMotion.systemReduceMotion ? Self.reducedDuration : Self.closeDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel, self.panel === panel, self.closing else { return }
                self.finishTeardown()
            }
        })
    }

    private func removeDismissalMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func finishTeardown() {
        removeDismissalMonitors()
        closing = false
        opening = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        pendingHeight = nil
        panelButton?.highlight(false)
        anchoredButton = nil
    }

    func stop() {
        stopped = true
        animationTimer?.invalidate()
        animationTimer = nil
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        motionObserver = nil
        for observer in workspaceNotifications { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceNotifications.removeAll()
        dismissPanel(animated: false)
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
        notifications.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
        for item in extraItems.values { NSStatusBar.system.removeStatusItem(item) }
        extraItems.removeAll()
    }
}

private final class WidgetPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
