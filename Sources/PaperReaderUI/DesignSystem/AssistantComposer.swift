import SwiftUI

extension View {
    func assistantComposerSurface(emphasized: Bool) -> some View {
        modifier(AssistantComposerSurface(emphasized: emphasized))
    }
}

private struct AssistantComposerSurface: ViewModifier {
    let emphasized: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return
            content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReaderTheme.surface, in: shape)
            .overlay {
                shape.strokeBorder(
                    emphasized ? ReaderTheme.accent : ReaderTheme.muted.opacity(0.55),
                    lineWidth: emphasized ? 1.5 : 1
                )
                .animation(ReaderMotion.feedback(reduceMotion), value: emphasized)
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
    }
}

struct AssistantSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(enabled ? ReaderTheme.surface : ReaderTheme.muted)
            .frame(width: 40, height: 40)
            .background(enabled ? ReaderTheme.accent : ReaderTheme.elevated, in: Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(ReaderMotion.feedback(reduceMotion), value: configuration.isPressed)
            .animation(ReaderMotion.feedback(reduceMotion), value: enabled)
    }
}
