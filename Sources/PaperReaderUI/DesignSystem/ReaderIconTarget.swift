import SwiftUI

extension ReaderTheme {
    static func iconTarget(_ desktopSize: CGFloat) -> CGFloat {
        #if os(iOS)
            max(desktopSize, 44)
        #else
            desktopSize
        #endif
    }
}

extension View {
    /// Apply to a button's label so its full visual slot responds to a tap.
    func readerIconTarget(macOS desktopSize: CGFloat = 28) -> some View {
        let minimum = ReaderTheme.iconTarget(desktopSize)
        return frame(minWidth: minimum, minHeight: minimum).contentShape(Rectangle())
    }

    /// Keep the native button in the key loop and draw focus around its entire target.
    func readerPlainButton(cornerRadius: CGFloat = 7) -> some View {
        modifier(ReaderPlainButton(cornerRadius: cornerRadius))
    }
}

private struct ReaderPlainButton: ViewModifier {
    let cornerRadius: CGFloat
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.buttonStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(ReaderTheme.accent, lineWidth: 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
