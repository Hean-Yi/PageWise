import SwiftUI

/// The current page is the only mounted surface. Its offset follows the same spring in either
/// direction, including when a new destination interrupts an unfinished navigation.
struct WorkspaceArrival: ViewModifier {
    let destination: CGPoint
    let background: Color
    var usesCompactNavigation = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        // In compact columns NavigationSplitView supplies the platform transition.
        let skipArrival = reduceMotion || (usesCompactNavigation && sizeClass == .compact)
        let location = CGPoint(
            x: layoutDirection == .rightToLeft ? -destination.x : destination.x, y: destination.y)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction(value: location) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .modifier(ArrivalSurface(location: location, destination: location, paper: background, moves: !skipArrival))
            .animation(ReaderMotion.navigation(skipArrival), value: location)
            .background(background)
            .clipped()
    }

    private struct ArrivalSurface: AnimatableModifier {
        var location: CGPoint
        let destination: CGPoint
        let paper: Color
        let moves: Bool

        nonisolated var animatableData: CGPoint.AnimatableData {
            get { location.animatableData }
            set { location.animatableData = newValue }
        }

        func body(content: Content) -> some View {
            let x = moves ? destination.x - location.x : 0
            let y = moves ? destination.y - location.y : 0
            let wash = min(0.18, Double(abs(x) + abs(y)) / 150)
            content
                .overlay {
                    paper.opacity(wash).allowsHitTesting(false).accessibilityHidden(true)
                }
                .offset(x: x, y: y)
        }
    }
}
