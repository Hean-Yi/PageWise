import SwiftUI

extension View {
    /// Apply only to the symbol inside a control. Slide an ink impression across
    /// its strokes while the underlying symbol, title and hit target stay in place.
    func readerSymbolInk() -> some View { modifier(SymbolInk()) }

    /// A SwiftUI Menu continues to own tracking, keyboard opening and dismissal.
    func readerMenuIconInteraction() -> some View {
        menuStyle(.button).buttonStyle(ReaderMenuLabel())
    }
}

struct ReaderSymbolLabelStyle: LabelStyle {
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        let label = Label {
            configuration.title
        } icon: {
            configuration.icon.readerSymbolInk()
        }
        if iconOnly { label.labelStyle(.iconOnly) } else { label.labelStyle(.titleAndIcon) }
    }
}

private struct ReaderMenuLabel: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuInk(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct MenuInk: View {
        let label: Configuration.Label
        let pressed: Bool
        @State private var hovered = false

        var body: some View {
            label.environment(\.readerIconInteraction, pressed ? .pressed : hovered ? .hovered : .idle)
                .onHover { hovered = $0 }
        }
    }
}

private struct SymbolInk: ViewModifier {
    @Environment(\.readerIconInteraction) private var interaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        let state = enabled && !reduceMotion ? interaction : .idle
        content.overlay {
            if state != .idle {
                // The second plate catches only the crossed strokes, like a two-colour print.
                LinearGradient(
                    colors: prominence == .increased
                        ? [.white, .white.opacity(0.65)] : [ReaderTheme.accent, ReaderTheme.ink],
                    startPoint: .leading, endPoint: .trailing
                )
                .mask(content)
                .mask(SymbolInkBand(center: state == .pressed ? 0.70 : 0.30))
                .offset(x: state == .pressed ? 0 : 0.75, y: state == .pressed ? 0.5 : -0.65)
                .transition(.offset(x: -1.6, y: 0.7).combined(with: .opacity))
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: state == .pressed ? 0.09 : 0.18), value: state)
    }
}

private struct SymbolInkBand: Shape {
    var center: CGFloat
    var animatableData: CGFloat {
        get { center }
        set { center = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let x = rect.minX + center * rect.width
        let width = rect.width
        var band = Path()
        band.move(to: CGPoint(x: x, y: rect.minY))
        band.addLine(to: CGPoint(x: x + 0.69 * width, y: rect.minY))
        band.addLine(to: CGPoint(x: x - 0.13 * width, y: rect.maxY))
        band.addLine(to: CGPoint(x: x - 0.82 * width, y: rect.maxY))
        band.closeSubpath()
        return band
    }
}
