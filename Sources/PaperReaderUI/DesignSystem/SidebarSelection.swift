import SwiftUI

private struct SidebarSelectionBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    func sidebarSelectionTarget(_ selected: Bool) -> some View {
        anchorPreference(key: SidebarSelectionBounds.self, value: .bounds) { selected ? $0 : nil }
    }

    /// Move one surface behind the controls. Labels, hit targets and keyboard focus stay in place.
    func sidebarSelectionIndicator(
        for selection: some Equatable, in shape: some InsettableShape, reduceMotion: Bool
    ) -> some View {
        backgroundPreferenceValue(SidebarSelectionBounds.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let rect = geometry[anchor]
                    Color.clear
                        .readerGlassSurface(in: shape, fallback: ReaderTheme.elevated)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(ReaderMotion.sidebar(reduceMotion), value: selection)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
