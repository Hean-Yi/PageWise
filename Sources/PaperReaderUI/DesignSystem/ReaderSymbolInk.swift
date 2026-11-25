import SwiftUI

/// System glyphs keep their normal metrics. Only the symbol receives the action's motion.
struct ReaderActionSymbol: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name).readerSymbolInk(ReaderSymbolMotion(name))
    }
}

enum ReaderSymbolMotion {
    case ink, left, right, up, down, outward, upperLeft, settings, retry, lens, blink, bookmark, write

    init(_ name: String) {
        switch name {
        case "arrow.left", "chevron.left", "chevron.backward", "arrow.uturn.backward": self = .left
        case "arrow.right", "chevron.right", "chevron.forward": self = .right
        case "arrow.up": self = .up
        case "arrow.down", "chevron.down", "chevron.down.2": self = .down
        case "arrow.up.right", "arrow.up.forward", "arrow.up.right.square": self = .outward
        case "arrow.up.left": self = .upperLeft
        case "gearshape", "gearshape.fill": self = .settings
        case "arrow.clockwise": self = .retry
        case "magnifyingglass", "text.magnifyingglass", "textformat.size": self = .lens
        case "eye": self = .blink
        case "bookmark", "bookmark.fill": self = .bookmark
        case "square.and.pencil", "note.text.badge.plus", "highlighter", "pencil.tip.crop.circle": self = .write
        default: self = .ink
        }
    }
}

extension View {
    func readerSymbolInk(_ motion: ReaderSymbolMotion = .ink) -> some View { modifier(SymbolInk(motion: motion)) }
}

struct ReaderSymbolLabelStyle: LabelStyle {
    var iconOnly = false
    var motion: ReaderSymbolMotion = .ink

    func makeBody(configuration: Configuration) -> some View {
        let label = Label {
            configuration.title
        } icon: {
            configuration.icon.readerSymbolInk(motion)
        }
        if iconOnly { label.labelStyle(.iconOnly) } else { label.labelStyle(.titleAndIcon) }
    }
}

private struct SymbolInk: ViewModifier {
    let motion: ReaderSymbolMotion
    @Environment(\.readerIconInteraction) private var interaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        let state = enabled && !reduceMotion ? interaction : .idle
        let amount: CGFloat = state == .pressed ? 1 : (state == .hovered ? 0.54 : 0)
        let effect = transform(amount)
        content
            .overlay {
                if state != .idle {
                    // Trace only the symbol's strokes, including for abstract commands without a direction.
                    (prominence == .increased ? Color.white : ReaderTheme.accent)
                        .mask(content).opacity(state == .pressed ? 0.95 : 0.65)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .scaleEffect(x: effect.scale.width, y: effect.scale.height)
            .rotationEffect(.degrees(effect.angle))
            .offset(effect.offset)
            .animation(reduceMotion ? nil : .easeInOut(duration: state == .pressed ? 0.11 : 0.22), value: state)
    }

    private func transform(_ amount: CGFloat) -> (offset: CGSize, scale: CGSize, angle: Double) {
        var offset = CGSize.zero
        var scale = CGSize(width: 1, height: 1)
        var angle = 0.0
        switch motion {
        case .left: offset.width = -3 * amount
        case .right: offset.width = 3 * amount
        case .up: offset.height = -3 * amount
        case .down: offset.height = 3 * amount
        case .outward: offset = CGSize(width: 2.5 * amount, height: -2.5 * amount)
        case .upperLeft: offset = CGSize(width: -2.5 * amount, height: -2.5 * amount)
        case .settings: angle = 26 * amount
        case .retry: angle = 40 * amount
        case .lens: scale = CGSize(width: 1 + 0.13 * amount, height: 1 + 0.13 * amount)
        case .blink: scale.height = 1 + (amount == 1 ? -0.32 : 0.12 * amount)
        case .bookmark: offset.height = amount == 1 ? 2.2 : -2.1 * amount
        case .write: offset = CGSize(width: 2 * amount, height: -amount)
        case .ink: break
        }
        return (offset, scale, angle)
    }
}
