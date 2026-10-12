import SwiftUI

/// Visual language: dark UI, a single indigo accent, pill pickers, sliders with Reset.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.33, blue: 0.98)
    static let accentSoft = Color(red: 0.62, green: 0.6, blue: 1.0)
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let control = Color(white: 1, opacity: 0.06)
    static let controlHover = Color(white: 1, opacity: 0.1)
    static let stroke = Color(white: 1, opacity: 0.08)
    static let secondaryText = Color(white: 1, opacity: 0.55)
    static let clip = Color(red: 0.86, green: 0.62, blue: 0.2)
    static let zoom = Color(red: 0.4, green: 0.34, blue: 0.95)
    static let mask = Color(red: 0.2, green: 0.62, blue: 0.55)
    static let layout = Color(red: 0.85, green: 0.35, blue: 0.55)
}

/// A titled section in a sidebar panel.
struct PanelSection<Content: View>: View {
    var title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Segmented "pill" buttons for an enum.
struct PillPicker<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var icon: ((T) -> String)? = nil

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    HStack(spacing: 5) {
                        if let icon { Image(systemName: icon(option)).font(.system(size: 11)) }
                        Text(label(option)).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.controlHover : Theme.control))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accentSoft.opacity(0.7) : .clear, lineWidth: 1))
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
                    Text(title).font(.system(size: 12))
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
                Text(title).font(.system(size: 12))
                if let help { Text(help).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Theme.accent)
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
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Theme.control))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control))
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
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.controlHover : Theme.control))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct IconButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .frame(width: 32, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.accent.opacity(0.25) : (configuration.isPressed ? Theme.controlHover : .clear)))
            .foregroundStyle(active ? Theme.accentSoft : .primary)
            .contentShape(Rectangle())
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

extension Color {
    init(_ c: RGBAColorConvertible) { self.init(red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

protocol RGBAColorConvertible {
    var r: Double { get }
    var g: Double { get }
    var b: Double { get }
    var a: Double { get }
}
