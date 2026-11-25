import SwiftUI

extension View {
    func readerContextMenu(_ title: String, items: @autoclosure @escaping () -> [ReaderMenuItem], width: CGFloat = 218)
        -> some View
    {
        modifier(ReaderContextMenu(title: title, items: items, width: width))
    }
}

private struct ReaderContextMenu: ViewModifier {
    let title: String
    let items: () -> [ReaderMenuItem]
    let width: CGFloat
    @State private var location: ReaderMenuLocation?
    @State private var open = false

    func body(content: Content) -> some View {
        content
            #if os(macOS)
                .overlay { ReaderSecondaryClick(action: present).accessibilityHidden(true) }
            #else
                .gesture(ReaderContextPress(action: present))
                .gesture(ReaderContextTap(action: present))
            #endif
            .accessibilityAction(named: Text(title)) {
                location = nil
                open = true
            }
            .readerMenuPresentation(open: $open, title: title, items: items, width: width, location: location)
    }

    private func present(at location: ReaderMenuLocation) {
        self.location = location
        open = true
    }
}
