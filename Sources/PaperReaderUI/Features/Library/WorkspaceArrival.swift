import SwiftUI

/// Swap the page immediately, then move only the new surface over its own opaque backing.
struct WorkspaceArrival<Page: Equatable & Sendable>: ViewModifier {
    let page: Page
    let distance: CGFloat
    let background: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        let moves = !reduceMotion && sizeClass != .compact
        let travel = layoutDirection == .rightToLeft ? -distance : distance
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction(value: page) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: page) { surface, offset in
                surface.offset(x: moves ? offset : 0)
            } keyframes: { _ in
                if moves {
                    MoveKeyframe(travel)
                    SpringKeyframe(0, duration: 0.34, spring: .snappy(duration: 0.34))
                } else {
                    MoveKeyframe(0)
                }
            }
            .background(background)
            .clipped()
    }
}
