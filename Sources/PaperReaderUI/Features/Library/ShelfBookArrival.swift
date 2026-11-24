import SwiftUI

/// Only newly inserted covers settle onto the shelf. SwiftUI interpolates the visual
/// transforms while layout, drop targets and keyboard focus use the destination slots.
enum ShelfBookArrival {
    static let duration = 0.30

    static func delay(position: Int, columns: Int) -> Double {
        let row = position / columns
        let column = position % columns
        // The stagger stays within one short beat, even far down a large shelf.
        return 0.012 * Double(min(column, 3)) + 0.006 * Double(row % 3)
    }

    static func transition(position: Int, columns: Int) -> AnyTransition {
        let animation = Animation.timingCurve(0.22, 0.78, 0.25, 1, duration: duration)
            .delay(delay(position: position, columns: columns))
        return .asymmetric(
            insertion: .modifier(active: Pose(lift: 1), identity: Pose(lift: 0)).animation(animation),
            removal: .identity)
    }

    private struct Pose: ViewModifier {
        let lift: CGFloat

        func body(content: Content) -> some View {
            content
                .scaleEffect(1 - 0.014 * lift, anchor: .bottom)
                .offset(y: -16 * lift)
                .opacity(1 - 0.40 * Double(lift))
        }
    }
}
