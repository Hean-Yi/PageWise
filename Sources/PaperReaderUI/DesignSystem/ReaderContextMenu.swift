import SwiftUI

extension View {
    func readerContextMenu(_ title: String, items: @autoclosure @escaping () -> [ReaderMenuItem]) -> some View {
        modifier(ReaderContextMenu(title: title, items: items))
    }
}

private struct ReaderContextMenu: ViewModifier {
    let title: String
    let items: () -> [ReaderMenuItem]
    @State private var point: CGPoint?
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
                point = nil
                open = true
            }
            .readerMenuPresentation(open: $open, title: title, items: items, width: 218, point: point)
    }

    private func present(at location: CGPoint) {
        point = location
        open = true
    }
}
