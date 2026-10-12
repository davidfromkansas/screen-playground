import SwiftUI

/// Light visual language with Liquid Glass. Glass is reserved for floating chrome and controls;
/// content (the video, timeline blocks) stays solid. One indigo tint marks the primary action;
/// red is reserved for Record.
enum Theme {
    static let accent = Color(red: 0.357, green: 0.357, blue: 0.965)        // #5B5BF6
    static let accentSoft = Color(red: 0.275, green: 0.275, blue: 0.902)    // #4646E6 — accent text / selection on light
    static let record = Color(red: 0.898, green: 0.208, blue: 0.176)        // #E5352D
    static let background = Color(red: 0.957, green: 0.961, blue: 0.973)    // #F4F5F8 ground
    /// Solid, calm backdrop behind all glass: a touch darker than the frosted panels so they read clearly.
    static let stage = Color(red: 0.914, green: 0.925, blue: 0.945)         // #E9ECF1
    static let panel = Color.white                                           // solid surface
    static let control = Color(red: 0.12, green: 0.12, blue: 0.24).opacity(0.06)
    static let controlHover = Color(red: 0.12, green: 0.12, blue: 0.24).opacity(0.10)
    static let stroke = Color(red: 0.12, green: 0.12, blue: 0.24).opacity(0.10)
    static let text = Color(red: 0.11, green: 0.11, blue: 0.118)            // #1C1C1E
    static let secondaryText = Color(red: 0.42, green: 0.42, blue: 0.447)   // #6B6B72
    static let clip = Color(red: 0.965, green: 0.769, blue: 0.325)          // #F6C453
    static let clipFast = Color(red: 0.953, green: 0.698, blue: 0.227)      // #F3B23A (sped up)
    static let clipText = Color(red: 0.29, green: 0.2, blue: 0.0)           // #4A3300
    static let zoom = Color(red: 0.416, green: 0.353, blue: 0.91)           // #6A5AE8
    static let mask = Color(red: 0.165, green: 0.616, blue: 0.576)          // #2A9D93
    static let layout = Color(red: 0.851, green: 0.349, blue: 0.549)
    static let success = Color(red: 0.204, green: 0.78, blue: 0.349)        // #34C759

    /// Concentric radii: panels hold controls inset by 4 pt.
    static let panelRadius: CGFloat = 26
    static let controlRadius: CGFloat = 18
}

// MARK: - Liquid Glass (macOS 26) with a frosted-material fallback (macOS 15)

enum GlassSupport {
    /// Debug: launch with `-PGFallbackGlass YES` to preview the macOS 15 look on macOS 26.
    static let forceFallback = UserDefaults.standard.bool(forKey: "PGFallbackGlass")
}

enum GlassKind: Equatable {
    case regular, clear
    case tinted(Color)
}

extension View {
    /// Floating glass surface. `cornerRadius == nil` gives a capsule.
    @ViewBuilder
    func glass(_ kind: GlassKind = .regular, cornerRadius: CGFloat? = nil, interactive: Bool = false) -> some View {
        let shape: AnyShape = cornerRadius.map { AnyShape(RoundedRectangle(cornerRadius: $0, style: .continuous)) } ?? AnyShape(Capsule())
        if #available(macOS 26.0, *), !GlassSupport.forceFallback {
            self.glassEffect(Self.liquidGlass(kind, interactive: interactive), in: shape)
        } else {
            self.background(Self.fallbackFill(kind), in: shape)
                .overlay(shape.stroke(Color.white.opacity(kind == .clear ? 0.55 : 0.75), lineWidth: 1))
                .shadow(color: Color(red: 0.12, green: 0.12, blue: 0.24).opacity(0.12), radius: 14, y: 8)
                .shadow(color: Color(red: 0.12, green: 0.12, blue: 0.24).opacity(0.06), radius: 1, y: 1)
        }
    }

    @available(macOS 26.0, *)
    private static func liquidGlass(_ kind: GlassKind, interactive: Bool) -> Glass {
        var g: Glass
        switch kind {
        case .regular: g = .regular
        case .clear: g = .clear
        case let .tinted(c): g = .regular.tint(c)
        }
        return interactive ? g.interactive() : g
    }

    private static func fallbackFill(_ kind: GlassKind) -> AnyShapeStyle {
        switch kind {
        case .regular: return AnyShapeStyle(.regularMaterial)
        case .clear: return AnyShapeStyle(.ultraThinMaterial)
        case let .tinted(c): return AnyShapeStyle(c.gradient)
        }
    }

    /// Groups nearby glass shapes so they blend and morph together on macOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *), !GlassSupport.forceFallback {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Primary action: tinted glass (one per window). Keeps its tint even when the window is
    /// inactive (e.g. behind a sheet), unlike the system prominent style.
    @ViewBuilder
    func primaryGlassButton(_ tint: Color = Theme.accent) -> some View {
        if #available(macOS 26.0, *), !GlassSupport.forceFallback {
            self.buttonStyle(LiquidTintedButtonStyle(tint: tint))
        } else {
            self.buttonStyle(TintedCapsuleButtonStyle(tint: tint))
        }
    }

    /// Record: tinted red glass.
    func recordGlassButton() -> some View { primaryGlassButton(Theme.record) }

    /// Secondary glass capsule button.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *), !GlassSupport.forceFallback {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(FallbackGlassButtonStyle())
        }
    }
}

/// macOS 26: tinted Liquid Glass capsule with a white label.
@available(macOS 26.0, *)
struct LiquidTintedButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 38)
            .glassEffect(.regular.tint(tint.opacity(isEnabled ? 1 : 0.45)).interactive(), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// macOS 15: gradient capsule standing in for prominent glass.
struct TintedCapsuleButtonStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 36)
            .background(Capsule().fill(tint.gradient))
            .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: tint.opacity(0.35), radius: 8, y: 4)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct FallbackGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .glass()
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Backwards-compatible name used across the app: the primary (tinted) button.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TintedCapsuleButtonStyle(tint: Theme.accent).makeBody(configuration: configuration)
    }
}

// MARK: - Panel building blocks

/// A titled section in a sidebar panel.
struct PanelSection<Content: View>: View {
    var title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Segmented "pill" options for an enum: selected pill is white with a soft shadow.
struct PillPicker<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var icon: ((T) -> String)? = nil

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    HStack(spacing: 5) {
                        if let icon { Image(systemName: icon(option)).font(.system(size: 11)) }
                        Text(label(option)).font(.system(size: 12, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Theme.accentSoft : Theme.text)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(selected ? Color.white : Theme.control)
                            .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 2, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Slider with a Reset button that is only enabled when the value differs from the default.
struct ResettableSlider: View {
    var title: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double>
    var defaultValue: Double
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(format(value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
            }
            HStack(spacing: 8) {
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged).tint(Theme.accent).controlSize(.small)
                Button("Reset") { value = defaultValue }
                    .buttonStyle(SmallButtonStyle())
                    .disabled(abs(value - defaultValue) < 0.0001)
            }
        }
    }
}

/// Toggle with optional grey help text.
struct HelpToggle: View {
    var title: String
    var help: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
                if let help { Text(help).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Collapsible "Advanced" style section.
struct Disclosure<Content: View>: View {
    var title: String
    @State private var open = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 26, height: 24).background(Circle().fill(Theme.control))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.control))
            }
        }
        .padding(.vertical, 8)
    }
}

struct SmallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(configuration.isPressed ? Theme.controlHover : Theme.control))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Round icon button used inside glass capsules.
struct IconButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15))
            .frame(width: 34, height: 34)
            .background(Circle().fill(active ? Theme.accent.opacity(0.14) : (configuration.isPressed ? Theme.controlHover : .clear)))
            .foregroundStyle(active ? Theme.accentSoft : Theme.text)
            .contentShape(Circle())
    }
}

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
