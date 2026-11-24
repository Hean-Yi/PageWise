import SwiftUI

/// A single, finite playback drives the cover artwork. Cells keep their final
/// layout, native drag targets and keyboard focus throughout the shelf change.
struct ShelfBookArrival: ViewModifier {
    nonisolated static let duration = 0.44
    let position: Int
    let columns: Int
    let fromTrailing: Bool
    @Environment(\.shelfArrivalTime) private var time

    func body(content: Content) -> some View {
        let lift = Self.lift(at: time, position: position, columns: columns, fromTrailing: fromTrailing)
        let lean = position.isMultiple(of: 2) ? -1.45 : 1.1
        content
            .rotationEffect(.degrees(lean * lift), anchor: .bottom)
            .offset(y: -22 * lift)
    }

    static func lift(at time: Double, position: Int, columns: Int, fromTrailing: Bool = false) -> Double {
        let row = position / columns
        let column = fromTrailing ? columns - 1 - position % columns : position % columns
        // Repeat the rhythm down a long shelf so a deep scroll has the same
        // short stagger as the first screen. No book waits more than 80 ms.
        let delay = 0.014 * Double(min(column, 4)) + 0.008 * Double(row % 4)
        let progress = min(1, max(0, (time - delay) / 0.36))
        let remaining = 1 - progress
        return remaining * remaining * (1 - 2.4 * progress)
    }
}

extension EnvironmentValues {
    @Entry var shelfArrivalTime = ShelfBookArrival.duration
}
