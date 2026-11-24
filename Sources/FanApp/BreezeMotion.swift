import AppKit
import Charts
import SwiftUI

// Motion system for Breeze. `.interface-design/motion.md` is the spec; pages
// never hard-code animation values, they call the API in this file.

// MARK: - Tokens

enum BreezeMotion {
    static let xs = 0.12   // press, focus ring
    static let s = 0.20    // hover, every exit
    static let m = 0.32    // default entrance
    static let l = 0.48    // journey step, layout morph, treemap drill
    static let xl = 0.80   // one-shot draws, count-ups, live-shape easing

    static let stagger = 0.045          // seconds between siblings
    static let staggerCap = 6           // later siblings share the last delay (max 0.27 s)
    static let travel: CGFloat = 12     // entrance offset

    enum Token: Sendable { case press, hover, settle, glide, drift, lift, enter, exit, ambient }

    /// One-shot draws and count-ups.
    static let draw = Animation.timingCurve(0.22, 1, 0.36, 1, duration: xl)
    /// Returned for every token when Reduce Motion is on.
    static let reduced = Animation.easeInOut(duration: 0.16)

    static func animation(_ token: Token, reduceMotion: Bool) -> Animation {
        if reduceMotion { return reduced }
        switch token {
        case .press: return .spring(response: 0.18, dampingFraction: 0.90)
        case .hover: return .spring(response: 0.26, dampingFraction: 0.86)
        case .settle: return .spring(response: 0.36, dampingFraction: 0.88)
        case .glide: return .spring(response: 0.48, dampingFraction: 0.90)
        case .drift: return .spring(response: 0.80, dampingFraction: 1.00)
        case .lift: return .spring(response: 0.42, dampingFraction: 0.72)
        case .enter: return .timingCurve(0.22, 1, 0.36, 1, duration: m)
        case .exit: return .timingCurve(0.4, 0, 1, 1, duration: s)
        case .ambient: return .easeInOut(duration: 2.4)
        }
    }

    /// The system Reduce Motion setting, read fresh on every call (for code outside view bodies).
    @MainActor static var systemReduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// withAnimation outside view bodies. Reads Reduce Motion on every call.
    @MainActor static func animate(_ token: Token = .settle, _ body: () -> Void) {
        withAnimation(animation(token, reduceMotion: systemReduceMotion), body)
    }

    static func delay(_ index: Int) -> Double { Double(min(max(index, 0), staggerCap)) * stagger }

    @MainActor private static var seen = Set<String>()
    @MainActor private static var asking = Set<String>()

    /// True for every caller in the main-queue turn that first asks for `key`, false for the rest of the app session.
    @MainActor static func firstTime(_ key: String) -> Bool {
        if seen.contains(key) { return false }
        if asking.insert(key).inserted {
            // Insert on the next turn so every sibling of one stagger group gets true.
            DispatchQueue.main.async { seen.insert(key); asking.remove(key) }
        }
        return true
    }

    /// clamp((temperature - 45) / (boost - 45), 0, 1); 0 when nil.
    static func heat(temperature: Double?, boost: Double) -> Double {
        guard let temperature else { return 0 }
        return min(max((temperature - 45) / max(boost - 45, 1), 0), 1)
    }

    /// Mint at 0, orange at 1, interpolated in hue so the midpoint stays clean. Never red (red is destructive only).
    static func thermalColor(_ heat: Double) -> Color {
        let t = min(max(heat, 0), 1)
        // mint (0.22, 0.67, 0.55) and orange (0.96, 0.55, 0.17) in HSB
        return Color(hue: 0.456 + (0.080 - 0.456) * t,
                     saturation: 0.672 + (0.823 - 0.672) * t,
                     brightness: 0.670 + (0.960 - 0.670) * t)
    }

    static func nearest<T>(_ samples: [T], to date: Date, by key: KeyPath<T, Date>) -> T? {
        samples.min { abs($0[keyPath: key].timeIntervalSince(date)) < abs($1[keyPath: key].timeIntervalSince(date)) }
    }
}

// MARK: - Energy gate

enum BreezeMotionLevel: Sendable, Equatable {
    case off, background, full
    var isActive: Bool { self != .off }
    /// TimelineView minimum interval: full 1/fps, background 1/min(fps, 10).
    func interval(fps: Double) -> Double {
        self == .background ? 1 / min(fps, 10) : 1 / max(fps, 1)
    }
}

extension EnvironmentValues {
    /// Perpetual motion allowed right now. `.off` outside `breezeMotionScope()`.
    @Entry var breezeMotionLevel: BreezeMotionLevel = .off
    /// 0...1 heat (`BreezeMotion.heat`), set by Dashboard; drives the backdrop aurora.
    @Entry var breezeHeat: Double = 0
    /// True while a Breeze hover button style is hovered or keyboard-focused (read by `breezeNudge`).
    @Entry var breezeHighlighted: Bool = false
}

@MainActor @Observable
private final class WindowMotionMonitor {
    private(set) var level: BreezeMotionLevel = .off
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored nonisolated(unsafe) private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    // Observers start on first attach: @State re-evaluates this initializer on every parent body pass.
    private func observe() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (center, NSWindow.didChangeOcclusionStateNotification),
            (center, NSWindow.didMiniaturizeNotification),
            (center, NSWindow.didDeminiaturizeNotification),
            (center, NSApplication.didBecomeActiveNotification),
            (center, NSApplication.didResignActiveNotification),
            (center, .NSProcessInfoPowerStateDidChange),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.screensDidWakeNotification)
        ]
        for (nc, name) in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.handle(name, window: window) }
            }
            tokens.append((nc, token))
        }
    }

    deinit { for (nc, token) in tokens { nc.removeObserver(token) } }

    func attach(_ window: NSWindow?) {
        if tokens.isEmpty { observe() }
        guard window !== self.window else { return }
        self.window = window
        update()
    }

    private func handle(_ name: Notification.Name, window: NSWindow?) {
        if name == NSWorkspace.screensDidSleepNotification { screensAsleep = true }
        if name == NSWorkspace.screensDidWakeNotification { screensAsleep = false }
        if let window, window !== self.window { return } // another window's occlusion or miniaturize
        update()
    }

    private func update() {
        let next: BreezeMotionLevel
        if let window, window.occlusionState.contains(.visible), !window.isMiniaturized,
           !screensAsleep, !ProcessInfo.processInfo.isLowPowerModeEnabled {
            next = NSApp.isActive ? .full : .background
        } else {
            next = .off
        }
        if next != level { level = next }
    }
}

private struct WindowCapture: NSViewRepresentable {
    let monitor: WindowMotionMonitor
    func makeNSView(context: Context) -> CaptureView { CaptureView(monitor: monitor) }
    func updateNSView(_ nsView: CaptureView, context: Context) { }

    final class CaptureView: NSView {
        let monitor: WindowMotionMonitor
        init(monitor: WindowMotionMonitor) { self.monitor = monitor; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("unused") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); monitor.attach(window) }
    }
}

private struct BreezeMotionScope: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var monitor = WindowMotionMonitor()

    func body(content: Content) -> some View {
        content
            .environment(\.breezeMotionLevel, reduceMotion ? .off : monitor.level)
            .background(WindowCapture(monitor: monitor).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

// MARK: - Transitions

private struct BreezeInsertionEffect: ViewModifier {
    var offset: CGSize
    var visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.offset(reduceMotion || visible ? .zero : offset).opacity(visible ? 1 : 0)
    }
}

/// Insertion half only: offset plus fade, offset dropped under Reduce Motion.
private struct BreezeInsertion: Transition {
    var offset: CGSize
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(BreezeInsertionEffect(offset: offset, visible: phase.isIdentity))
    }
}

extension AnyTransition {
    @MainActor private static func breezeInsert(_ offset: CGSize) -> AnyTransition {
        .asymmetric(insertion: AnyTransition(BreezeInsertion(offset: offset)),
                    removal: AnyTransition.opacity.animation(BreezeMotion.animation(.exit, reduceMotion: BreezeMotion.systemReduceMotion)))
    }
    /// Insertion y +6 (forward) or -6; removal = exit fade.
    @MainActor static func breezePage(forward: Bool) -> AnyTransition { breezeInsert(CGSize(width: 0, height: forward ? 6 : -6)) }
    /// Insertion x +24 (forward) or -24; removal = exit fade.
    @MainActor static func breezeStep(forward: Bool) -> AnyTransition { breezeInsert(CGSize(width: forward ? 24 : -24, height: 0)) }
    /// Insertion y -8; removal = exit fade.
    @MainActor static var breezeDrop: AnyTransition { breezeInsert(CGSize(width: 0, height: -8)) }
    /// Opacity; removal = exit fade.
    @MainActor static var breezeFade: AnyTransition { breezeInsert(.zero) }
}

private final class DirectionBox {
    private var last: Int?
    private var forward = true
    func forward(for index: Int) -> Bool {
        if let last, index != last { forward = index > last }
        last = index
        return forward
    }
}

/// The one way to switch keyed content (pages, tabs, workspaces, journey steps).
/// Content inside must not add its own insertion transition or reveal to its initial state.
struct BreezeSwitcher<Key: Hashable, Content: View>: View {
    private let key: Key
    private let index: Int
    private let axis: Axis
    private let token: BreezeMotion.Token
    private let content: Content
    @State private var direction = DirectionBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ key: Key, index: Int, axis: Axis = .horizontal, token: BreezeMotion.Token = .settle,
         @ViewBuilder content: () -> Content) {
        self.key = key
        self.index = index
        self.axis = axis
        self.token = token
        self.content = content()
    }

    var body: some View {
        let forward = direction.forward(for: index)
        ZStack(alignment: .top) {
            content
                .id(key)
                .transition(axis == .vertical ? .breezePage(forward: forward) : .breezeStep(forward: forward))
        }
        .animation(BreezeMotion.animation(token, reduceMotion: reduceMotion), value: key)
    }
}

// MARK: - Reveal, animation, live text

private struct BreezeReveal: ViewModifier {
    let index: Int
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(index: Int, key: String) {
        self.index = index
        _shown = State(initialValue: !BreezeMotion.firstTime(key))
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : BreezeMotion.travel)
            .onAppear {
                guard !shown else { return }
                let animation = reduceMotion ? BreezeMotion.reduced
                    : BreezeMotion.animation(.enter, reduceMotion: false).delay(BreezeMotion.delay(index))
                withAnimation(animation) { shown = true }
            }
    }
}

private struct BreezeTokenAnimation<V: Equatable>: ViewModifier {
    let token: BreezeMotion.Token
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(BreezeMotion.animation(token, reduceMotion: reduceMotion), value: value)
    }
}

private struct BreezeNumeric: ViewModifier {
    let value: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(value.map { reduceMotion ? .opacity : .numericText(value: $0) } ?? .identity)
            .animation(BreezeMotion.animation(.settle, reduceMotion: reduceMotion), value: value)
    }
}

private struct BreezeNudge: ViewModifier {
    let offset: CGSize
    @Environment(\.breezeHighlighted) private var highlighted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(BreezeMotion.animation(.hover, reduceMotion: reduceMotion)) {
            $0.offset(highlighted && !reduceMotion ? offset : .zero)
        }
    }
}

private enum PulsePhase: CaseIterable { case rest, start, end }

private struct BreezePulse<T: Equatable>: ViewModifier {
    let trigger: T
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.background {
            // A circle on square hosts (dots, rings, seals), a halo around wide ones (the Review button).
            Capsule().stroke(tint, lineWidth: 2)
                .phaseAnimator(PulsePhase.allCases, trigger: trigger) { ring, phase in
                    ring.scaleEffect(phase == .end ? 1.6 : 1).opacity(phase == .start ? 0.5 : 0)
                } animation: { phase in
                    phase == .end ? .timingCurve(0.22, 1, 0.36, 1, duration: BreezeMotion.l) : .linear(duration: 0.01)
                }
                .opacity(reduceMotion ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Main window root only (Dashboard). Publishes `breezeMotionLevel` for everything inside.
    func breezeMotionScope() -> some View { modifier(BreezeMotionScope()) }

    func breezeAnimation<V: Equatable>(_ token: BreezeMotion.Token, value: V) -> some View {
        modifier(BreezeTokenAnimation(token: token, value: value))
    }

    /// First time per session for `key`: opacity + y 12 with `enter` after `delay(index)`. Later visits render at rest.
    func breezeReveal(_ index: Int = 0, key: String) -> some View { modifier(BreezeReveal(index: index, key: key)) }

    /// Rolling numerals for user-caused values, discrete results, countdowns and the hero RPM. nil leaves the text untouched.
    func breezeNumeric(_ value: Double?) -> some View { modifier(BreezeNumeric(value: value)) }

    /// Sensor, timer and stream text: tabular digits, no content transition.
    func breezeLive() -> some View {
        monospacedDigit().contentTransition(.identity).accessibilityAddTraits(.updatesFrequently)
    }

    /// One expanding ring on a state change (never per sample).
    func breezePulse<T: Equatable>(trigger: T, tint: Color = BreezeStyle.mint) -> some View {
        modifier(BreezePulse(trigger: trigger, tint: tint))
    }

    /// Moves by `offset` while the enclosing Breeze hover style is hovered or focused (row chevron, card arrow).
    func breezeNudge(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(BreezeNudge(offset: CGSize(width: x, height: y)))
    }
}

// MARK: - Hover button styles

private struct BreezeFocusRing: View {
    let radius: CGFloat
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
            .inset(by: -3)
            .strokeBorder(BreezeStyle.mint.opacity(visible ? 0.8 : 0), lineWidth: 2)
            .animation(BreezeMotion.animation(.press, reduceMotion: reduceMotion), value: visible)
            .allowsHitTesting(false)
    }
}

/// Doors to other pages: lift, deeper shadow and a pointer spotlight; keyboard focus shows the same lift plus the ring.
struct BreezeCardButtonStyle: ButtonStyle {
    var radius: CGFloat = 20
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, radius: radius) }

    private struct Styled: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        @State private var pointer: CGPoint?

        var body: some View {
            let active = enabled && (hovering || focused)
            let lifted = active && !configuration.isPressed && !reduceMotion
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .environment(\.breezeHighlighted, active)
                .overlay {
                    if reduceMotion {
                        shape.fill(Color.primary.opacity(active ? 0.05 : 0)).allowsHitTesting(false)
                    } else if let pointer, active, !spotlightSuppressed {
                        Circle()
                            .fill(RadialGradient(colors: [.white.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 120))
                            .frame(width: 240, height: 240)
                            .position(pointer)
                            .clipShape(shape)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(BreezeFocusRing(radius: radius, visible: enabled && focused))
                .contentShape(shape)
                .animation(BreezeMotion.animation(.hover, reduceMotion: reduceMotion)) {
                    $0.offset(y: lifted ? -2 : 0)
                        .shadow(color: .black.opacity(0.12), radius: lifted ? 12 : 6, y: lifted ? 6 : 2)
                }
                .opacity(enabled ? 1 : 0.5)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovering = true; pointer = point
                    case .ended: hovering = false; pointer = nil
                    }
                }
        }

        // macOS 26 interactive glass supplies its own highlight.
        private var spotlightSuppressed: Bool {
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }
}

/// Rows that navigate or open something: primary 5% background; pair with `.breezeNudge(x: 2)` on the chevron.
struct BreezeRowButtonStyle: ButtonStyle {
    var radius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, radius: radius) }

    private struct Styled: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let active = enabled && (hovering || focused)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .environment(\.breezeHighlighted, active)
                .background {
                    shape.fill(Color.primary.opacity(enabled && configuration.isPressed ? 0.09 : active ? 0.05 : 0))
                        .animation(BreezeMotion.animation(.hover, reduceMotion: reduceMotion), value: active)
                }
                .overlay(BreezeFocusRing(radius: radius, visible: enabled && focused))
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// Treemap and similar coloured tiles: +8% brightness and a 1 pt inner stroke.
struct BreezeTileButtonStyle: ButtonStyle {
    var radius: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, radius: radius) }

    private struct Styled: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let active = enabled && (hovering || focused)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .environment(\.breezeHighlighted, active)
                .animation(BreezeMotion.animation(.hover, reduceMotion: reduceMotion)) {
                    $0.brightness(enabled && configuration.isPressed ? 0.04 : active ? 0.08 : 0)
                }
                .overlay {
                    shape.strokeBorder(.white.opacity(active ? 0.55 : 0), lineWidth: 1)
                        .animation(BreezeMotion.animation(.hover, reduceMotion: reduceMotion), value: active)
                        .allowsHitTesting(false)
                }
                .overlay(BreezeFocusRing(radius: radius, visible: enabled && focused))
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == BreezeCardButtonStyle { static var breezeCard: Self { .init() } }
extension ButtonStyle where Self == BreezeRowButtonStyle { static var breezeRow: Self { .init() } }
extension ButtonStyle where Self == BreezeTileButtonStyle { static var breezeTile: Self { .init() } }

// MARK: - Perpetual: airflow and fan glyph

/// Integrates time and distance from TimelineView dates; never written to observable state.
private final class PhaseBox {
    private var last: Date?
    private(set) var time = 0.0
    private(set) var distance = 0.0
    func advance(to date: Date, running: Bool, velocity: Double) {
        defer { last = date }
        guard running, let last else { return }
        let dt = min(max(date.timeIntervalSince(last), 0), 0.25)
        time += dt
        distance += velocity * dt
    }
}

/// Fan effort and heat as one physical metaphor. Hero only; mask and placement belong to the caller.
struct BreezeAirflow: View {
    let speed: Double
    let heat: Double
    let density: Double
    @State private var box = PhaseBox()
    @Environment(\.breezeMotionLevel) private var level
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    init(speed: Double, heat: Double, density: Double = 1) {
        self.speed = min(max(speed, 0), 1)
        self.heat = heat
        self.density = density
    }

    var body: some View {
        if !(reduceTransparency || contrast == .increased) {
            let frozen = reduceMotion || speed <= 0
            TimelineView(.animation(minimumInterval: level.interval(fps: 30), paused: frozen || !level.isActive)) { timeline in
                let velocity = 18 + 120 * speed
                let _ = box.advance(to: timeline.date, running: !frozen && level.isActive, velocity: velocity)
                let time = box.time, distance = box.distance
                let speed = speed, density = density, dark = scheme == .dark
                let color = BreezeMotion.thermalColor(heat)
                Canvas { context, size in
                    Self.draw(in: &context, size: size, time: time, distance: distance, speed: speed,
                              density: density, color: color, dark: dark)
                }
                .opacity(frozen ? 0.6 : 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private static func hash(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, time: Double, distance: Double,
                             speed: Double, density: Double, color: Color, dark: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let count = min(Int(16 + 40 * speed * density), 56)
        let length = 10 + 36 * speed
        let span = size.width + length
        let (low, high) = dark ? (0.10, 0.30) : (0.08, 0.22)
        for i in 0..<count {
            let y0 = hash(i, 1) * size.height
            let amplitude = 6 + 8 * hash(i, 2)
            let seedPhase = hash(i, 3) * 2 * .pi
            let pace = 0.8 + 0.4 * hash(i, 4) // depth: near streaks travel a little faster
            let head = (hash(i, 5) * span + distance * pace).truncatingRemainder(dividingBy: span)
            let tail = head - length
            func point(_ x: Double) -> CGPoint {
                CGPoint(x: x, y: y0 + amplitude * sin(x / 180 + seedPhase + time * 0.3))
            }
            var path = Path()
            path.move(to: point(tail))
            for step in 1...4 { path.addLine(to: point(tail + length * Double(step) / 4)) }
            let opacity = low + (high - low) * hash(i, 6)
            context.stroke(path,
                           with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(opacity)]),
                                                 startPoint: point(tail), endPoint: point(head)),
                           style: StrokeStyle(lineWidth: 1 + 0.5 * hash(i, 7), lineCap: .round))
        }
    }
}

/// A fan symbol spinning at min(rpm / 3000, 3) rev/s under the motion gate; static under 1 RPM.
struct BreezeFanGlyph: View {
    let rpm: Double
    let size: CGFloat
    let weight: Font.Weight
    let tint: Color
    @State private var box = PhaseBox()
    @Environment(\.breezeMotionLevel) private var level
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(rpm: Double, size: CGFloat, weight: Font.Weight = .light, tint: Color = BreezeStyle.mint) {
        self.rpm = rpm
        self.size = size
        self.weight = weight
        self.tint = tint
    }

    var body: some View {
        let running = level.isActive && !reduceMotion && rpm >= 1
        TimelineView(.animation(minimumInterval: level.interval(fps: 30), paused: !running)) { timeline in
            let _ = box.advance(to: timeline.date, running: running, velocity: 360 * min(rpm / 3000, 3))
            Image(systemName: "fanblades.fill")
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(box.distance.truncatingRemainder(dividingBy: 360)))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Shapes: ring and meter

/// Appears at its value (never draws from 0) and follows with `drift`. Add the label of the control it replaces.
struct BreezeRing: View {
    let fraction: Double
    let lineWidth: CGFloat
    let tint: Color
    let endTint: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fraction: Double, lineWidth: CGFloat = 9, tint: Color = BreezeStyle.mint, endTint: Color? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.lineWidth = lineWidth
        self.tint = tint
        self.endTint = endTint
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [tint, endTint ?? tint], center: .center,
                                        startAngle: .zero, endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(BreezeMotion.animation(.drift, reduceMotion: reduceMotion), value: fraction)
        }
        .padding(lineWidth / 2)
        .accessibilityRepresentation { ProgressView(value: fraction) }
    }
}

/// Horizontal meter at its value; follows with `drift`. `nil` is the empty track; `marker` is a 2 pt tick (e.g. target).
struct BreezeMeter: View {
    let fraction: Double?
    let tint: Color
    let height: CGFloat
    let marker: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fraction: Double?, tint: Color = BreezeStyle.mint, height: CGFloat = 6, marker: Double? = nil) {
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.tint = tint
        self.height = height
        self.marker = marker.map { min(max($0, 0), 1) }
    }

    var body: some View {
        let animation = BreezeMotion.animation(.drift, reduceMotion: reduceMotion)
        let value = fraction ?? 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // The track keeps its own height; only a marker needs the extra 4 pt.
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: height)
                Capsule().fill(tint)
                    .frame(width: max(geo.size.width * value, value > 0 ? height : 0), height: height)
                    .opacity(value > 0 ? 1 : 0)
                    .animation(animation, value: fraction)
                if let marker {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2, height: height + 4)
                        .offset(x: min(max(geo.size.width * marker - 1, 0), geo.size.width - 2))
                        .animation(animation, value: marker)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: marker == nil ? height : height + 4)
        .accessibilityRepresentation { ProgressView(value: fraction) }
    }
}

// MARK: - Count-up, delayed progress

private struct CountUpText: View, Animatable {
    var value: Double
    let format: (Double) -> String
    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(format(value)).monospacedDigit() }
}

/// 0 to value once over `xl`. Speed test result and Cleanup receipt only. VoiceOver reads the final value.
struct BreezeCountUp: View {
    let value: Double
    let format: (Double) -> String
    @State private var started = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `key`: count up only the first time this result is shown in the session (pages are rebuilt on every visit).
    init(_ value: Double, key: String? = nil, format: @escaping (Double) -> String) {
        self.value = value
        self.format = format
        _started = State(initialValue: key.map { !BreezeMotion.firstTime($0) } ?? false)
    }

    var body: some View {
        CountUpText(value: started || reduceMotion ? value : 0, format: format)
            .accessibilityElement(children: .ignore)
            .accessibilityValue(Text(format(value)))
            .onAppear {
                guard !started else { return }
                if reduceMotion { started = true } else { withAnimation(BreezeMotion.draw) { started = true } }
            }
    }
}

/// Nothing for 0.3 s, then a ProgressView that fades in. Avoids a spinner flash on fast loads.
struct BreezeDelayedProgress: View {
    let label: String?
    @State private var visible = false

    init(_ label: String? = nil) { self.label = label }

    var body: some View {
        // Kept in layout at opacity 0 so its arrival never shifts the page.
        Group {
            if let label { ProgressView(label) } else { ProgressView() }
        }
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            BreezeMotion.animate(.enter) { visible = true }
        }
    }
}

// MARK: - Page header

/// Title 28 semibold rounded, subtitle, trailing controls; `scrolled` fades in a bottom hairline.
struct BreezePageHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String
    private let scrolled: Bool
    private let trailing: Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, subtitle: String, scrolled: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.scrolled = scrolled
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(BreezeStyle.Typography.title)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, BreezeStyle.pagePadding)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(scrolled ? 1 : 0)
                .animation(BreezeMotion.animation(.settle, reduceMotion: reduceMotion), value: scrolled)
        }
    }
}

extension BreezePageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String, scrolled: Bool = false) {
        self.init(title, subtitle: subtitle, scrolled: scrolled) { EmptyView() }
    }
}

extension View {
    /// On the scroll content: sets `scrolled` once content has moved 8 pt under the top edge.
    func breezeScrollEdge(_ scrolled: Binding<Bool>) -> some View {
        onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY < -8 } action: { value in
            if scrolled.wrappedValue != value { scrolled.wrappedValue = value }
        }
    }
}

// MARK: - Chart kit

private struct BreezeChartDrawIn: ViewModifier {
    @State private var drawn: Bool
    @State private var finished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(key: String) {
        let first = BreezeMotion.firstTime(key)
        _drawn = State(initialValue: !first)
        _finished = State(initialValue: !first)
    }

    func body(content: Content) -> some View {
        if finished {
            content
        } else {
            content
                .mask {
                    Rectangle()
                        .scaleEffect(x: drawn || reduceMotion ? 1 : 0.001, y: 1, anchor: .leading)
                        .opacity(drawn || !reduceMotion ? 1 : 0)
                }
                .onAppear {
                    withAnimation(reduceMotion ? BreezeMotion.reduced : BreezeMotion.draw) { drawn = true } completion: {
                        finished = true // drop the mask so scrub callouts can overflow the plot
                    }
                }
        }
    }
}

private struct BreezeChartScrub: ViewModifier {
    @Binding var selection: Date?
    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let point) = phase, let plotFrame = proxy.plotFrame else {
                            selection = nil
                            return
                        }
                        let plot = geo[plotFrame]
                        let x = min(max(point.x - plot.minX, 0), plot.width)
                        selection = proxy.value(atX: x, as: Date.self)
                    }
            }
        }
    }
}

private struct BreezeChartKeys: ViewModifier {
    @Binding var selection: Date?
    let dates: [Date]
    func body(content: Content) -> some View {
        content
            // Keyboard navigation only, like a button: a click never focuses (and rings) the whole chart group.
            .focusable(interactions: .activate)
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .onKeyPress(.escape) {
                guard selection != nil else { return .ignored }
                selection = nil
                return .handled
            }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard !dates.isEmpty else { return .ignored }
        guard let current = selection,
              let index = dates.indices.min(by: { abs(dates[$0].timeIntervalSince(current)) < abs(dates[$1].timeIntervalSince(current)) })
        else {
            selection = dates.last
            return .handled
        }
        selection = dates[min(max(index + delta, 0), dates.count - 1)]
        return .handled
    }
}

extension View {
    /// Inside `chartPlotStyle { $0.breezeChartDrawIn(key:) }`: leading-to-trailing reveal once per session per key.
    func breezeChartDrawIn(key: String) -> some View { modifier(BreezeChartDrawIn(key: key)) }

    /// On the Chart: pointer hover maps to a date, cleared on exit. The rule tracks 1:1, never animated.
    func breezeChartScrub(_ selection: Binding<Date?>) -> some View { modifier(BreezeChartScrub(selection: selection)) }

    /// On the chart or chart group: one focus stop; left/right step one sample of `dates` (ascending), Escape clears.
    func breezeChartKeys(_ selection: Binding<Date?>, dates: [Date]) -> some View {
        modifier(BreezeChartKeys(selection: selection, dates: dates))
    }
}

/// The scrub annotation: `.annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled))`.
struct BreezeChartCallout: View {
    let title: String
    let value: String
    let tint: Color

    init(title: String, value: String, tint: Color = BreezeStyle.mint) {
        self.title = title
        self.value = value
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .breezeSurface(radius: 8)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
