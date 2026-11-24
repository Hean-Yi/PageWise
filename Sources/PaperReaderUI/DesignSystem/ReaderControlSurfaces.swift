import SwiftUI

extension View {
    func readerGlassSurface(
        in shape: some InsettableShape, fallback: Color = ReaderTheme.surface, bordered: Bool = false
    ) -> some View {
        background {
            ReaderControlBackdrop(shape: shape, fallback: fallback, bordered: bordered)
                .accessibilityHidden(true).allowsHitTesting(false)
        }
    }

    func readerFloatingButton(_ shape: ButtonBorderShape) -> some View {
        modifier(ReaderFloatingButtonStyle(shape: shape))
    }

    @ViewBuilder func readerGlassGroup() -> some View {
        if #available(macOS 26, iOS 26, *) {
            GlassEffectContainer(spacing: 0) { self }
        } else {
            self
        }
    }

    @ViewBuilder func readerSystemToolbarBackground() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self
        } else {
            #if os(macOS)
                toolbarBackground(ReaderTheme.canvas, for: .windowToolbar)
                    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            #else
                toolbarBackground(ReaderTheme.canvas, for: .navigationBar)
            #endif
        }
    }
}

private struct ReaderControlBackdrop<Surface: InsettableShape>: View {
    let shape: Surface
    let fallback: Color
    let bordered: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if #available(macOS 26, iOS 26, *), !reduceTransparency {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(fallback).overlay {
                if bordered { shape.strokeBorder(ReaderTheme.line) }
            }
        }
    }
}

private struct ReaderFloatingButtonStyle: ViewModifier {
    let shape: ButtonBorderShape
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *), !reduceTransparency {
            content.buttonStyle(.glass).buttonBorderShape(shape).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(shape).controlSize(.large)
                .background(ReaderTheme.surface, in: shape)
        }
    }
}
