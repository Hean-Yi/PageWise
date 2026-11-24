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
}
