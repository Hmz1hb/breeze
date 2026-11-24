import AppKit
import SwiftUI

enum BreezeStyle {
    static let mint = Color(red: 0.22, green: 0.67, blue: 0.55)
    static let blue = Color(red: 0.38, green: 0.55, blue: 0.88)
    /// Horizontal page padding on every page.
    static let pagePadding: CGFloat = 28

    /// Switch to these when touching a text; no mass rename.
    enum Typography {
        static let display = Font.system(size: 42, weight: .light, design: .rounded)
        static let title = Font.system(size: 28, weight: .semibold, design: .rounded)
        static let numeralL = Font.system(size: 27, weight: .medium, design: .rounded)
        static let numeralM = Font.system(size: 21, weight: .medium, design: .rounded)
        /// Use with `.tracking(Typography.eyebrowTracking)`.
        static let eyebrow = Font.system(size: 9, weight: .semibold)
        static let eyebrowTracking: CGFloat = 1.0
    }
}

/// Thermal aurora: three fixed radial fields over the behind-window material. The heat
/// field follows `breezeHeat` with hysteresis, so a reading on a boundary never retriggers it.
struct BreezeBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.breezeHeat) private var heat
    @Environment(\.breezeMotionLevel) private var level
    @State private var gate = HeatGate()
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            if reduceTransparency || contrast == .increased {
                Color(nsColor: .windowBackgroundColor)
            } else {
                BreezeWindowMaterial()
                field(BreezeStyle.mint.opacity(0.10), at: UnitPoint(x: 0.15, y: 0.10))
                field(BreezeStyle.blue.opacity(0.06), at: UnitPoint(x: 0.90, y: 0.95))
                field(BreezeMotion.thermalColor(shown).opacity(0.05 + 0.09 * shown), at: UnitPoint(x: 0.62, y: 0.22))
            }
        }
        .ignoresSafeArea()
        .onChange(of: heat, initial: true) {
            guard gate.offer(heat, now: .now) else { return }
            // Animate only where it can be seen; otherwise the value waits for the window to return.
            if level.isActive || reduceMotion {
                withAnimation(BreezeMotion.animation(.ambient, reduceMotion: reduceMotion)) { shown = gate.applied }
            }
        }
        .onChange(of: level.isActive) { _, active in
            if active, shown != gate.applied { shown = gate.applied }
        }
    }

    private func field(_ color: Color, at center: UnitPoint) -> some View {
        Rectangle().fill(RadialGradient(colors: [color, color.opacity(0)], center: center, startRadius: 0, endRadius: 520))
    }

    /// Applies a new 0.05 heat step when it differs by 0.10 or more, or when the same
    /// different step has been pending for 10 s or more.
    struct HeatGate {
        private(set) var applied = 0.0
        private var pending: (step: Int, since: Date)?

        mutating func offer(_ heat: Double, now: Date) -> Bool {
            let step = Int((min(max(heat, 0), 1) * 20).rounded())
            let current = Int((applied * 20).rounded())
            if step == current { pending = nil; return false }
            if abs(step - current) >= 2 || (pending?.step == step && now.timeIntervalSince(pending!.since) >= 10) {
                applied = Double(step) / 20
                pending = nil
                return true
            }
            if pending?.step != step { pending = (step, now) }
            return false
        }
    }
}

// Behind-window blending lets the desktop inform the material. An opaque
// SwiftUI window background would hide this, even with glass on the sidebar.
private struct BreezeWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowMaterialView {
        let view = WindowMaterialView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: WindowMaterialView, context: Context) { }

    final class WindowMaterialView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
    }
}

// Glass belongs to navigation and controls. Data uses a quieter material so
// charts, tables and labels stay readable without stacking glass on glass.
private struct BreezeSurface: ViewModifier {
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.25)))
        } else {
            content.background(.thinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
        }
    }
}

struct BreezeGlass: ViewModifier {
    var radius: CGFloat = 20
    var interactive = false
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.25)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        }
    }
}

struct BreezeGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// Intent: a Mac owner scanning dense controls should recognize the next action
// immediately. SF labels, four-point spacing and an eight-point corner radius
// keep every action aligned. Mint marks the primary action; quiet neutral
// surfaces and separator borders keep supporting actions in the background.
struct BreezeButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var height: CGFloat {
        switch size {
        case .mini: 24
        case .small: 28
        case .large: 38
        default: 34
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let accent = destructive ? Color.red : BreezeStyle.mint
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: size == .mini || size == .small ? 12 : 13, weight: .medium))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, size == .mini ? 8 : 12)
            .frame(minWidth: size == .mini ? 24 : 34)
            .frame(height: height)
            .foregroundStyle(prominent ? (destructive ? Color.white : Color.black.opacity(0.88)) : (destructive ? Color.red : Color.primary))
            .background(prominent ? accent : Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.fill(Color.primary.opacity(enabled && configuration.isPressed ? 0.12 : enabled && hovering ? 0.06 : 0))
                .animation(BreezeMotion.animation(.hover, reduceMotion: reduceMotion), value: hovering))
            .overlay(shape.strokeBorder(prominent ? accent.opacity(0.6) : Color.primary.opacity(contrast == .increased ? 0.4 : 0.14), lineWidth: 1))
            .overlay(shape.inset(by: -3).strokeBorder(BreezeStyle.mint.opacity(enabled && focused ? 0.8 : 0), lineWidth: 2)
                .animation(BreezeMotion.animation(.press, reduceMotion: reduceMotion), value: focused))
            .opacity(enabled ? 1 : 0.42)
            .contentShape(shape)
            .animation(BreezeMotion.animation(.press, reduceMotion: reduceMotion)) {
                // Labels are single-line at a fixed height, so the press scale cannot shimmer text.
                $0.scaleEffect(enabled && configuration.isPressed && !reduceMotion ? 0.97 : 1)
            }
            .onHover { hovering = $0 }
    }
}

struct BreezeActionStyle: ViewModifier {
    var prominent = false
    var size: ControlSize = .regular
    func body(content: Content) -> some View {
        content.buttonStyle(BreezeButtonStyle(prominent: prominent)).controlSize(size)
    }
}

extension View {
    func breezeSurface(radius: CGFloat = 20) -> some View { modifier(BreezeSurface(radius: radius)) }
    func breezeGlass(radius: CGFloat = 20, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(BreezeGlass(radius: radius, interactive: interactive, tint: tint))
    }
    func breezeAction(prominent: Bool = false, size: ControlSize = .regular) -> some View {
        modifier(BreezeActionStyle(prominent: prominent, size: size))
    }
}

/// A disclosure group whose title text also toggles it, not just the arrow.
struct BreezeDisclosure<Content: View>: View {
    private let title: String
    private let content: Content
    @State private var expanded = false

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) { content } label: {
            Button(title) { BreezeMotion.animate(.settle) { expanded.toggle() } }
                .buttonStyle(.plain)
                .accessibilityHidden(true) // the group itself is the accessible toggle
        }
    }
}
