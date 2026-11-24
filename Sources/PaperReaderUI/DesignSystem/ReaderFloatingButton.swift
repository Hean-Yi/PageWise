import SwiftUI

extension View {
    @ViewBuilder func readerFloatingButton(_ shape: ButtonBorderShape) -> some View {
        if #available(macOS 26, iOS 26, *) {
            buttonStyle(.glass).buttonBorderShape(shape).controlSize(.large)
        } else {
            buttonStyle(.bordered).buttonBorderShape(shape).controlSize(.large)
                .background(ReaderTheme.surface, in: shape)
        }
    }
}
