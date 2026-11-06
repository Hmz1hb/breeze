import AppKit
import SwiftUI

enum BreezeStyle {
    static let mint = Color(red: 0.22, green: 0.67, blue: 0.55)
    static let blue = Color(red: 0.38, green: 0.55, blue: 0.88)
}

struct BreezeBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if reduceTransparency || contrast == .increased {
                Color(nsColor: .windowBackgroundColor)
            } else {
                BreezeWindowMaterial()
                LinearGradient(colors: [BreezeStyle.mint.opacity(0.08), .clear, BreezeStyle.blue.opacity(0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea()
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
            .overlay(shape.fill(Color.primary.opacity(enabled && configuration.isPressed ? 0.12 : enabled && hovering ? 0.06 : 0)))
            .overlay(shape.strokeBorder(prominent ? accent.opacity(0.6) : Color.primary.opacity(contrast == .increased ? 0.4 : 0.14), lineWidth: 1))
            .overlay(shape.inset(by: -3).strokeBorder(BreezeStyle.mint.opacity(enabled && focused ? 0.8 : 0), lineWidth: 2))
            .opacity(enabled ? 1 : 0.42)
            .contentShape(shape)
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
