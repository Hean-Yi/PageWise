import SwiftUI

/// A moving mask inks the existing linework. The gray proof underneath stays visible until the ink reaches it.
struct SidebarIconFill: Shape {
    let glyph: ReaderIcon.Glyph
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        if progress >= 1 { return Path(rect) }
        var mask = Path()
        switch glyph {
        case .library:
            // The book spines take the ink from their heads down to the shelf.
            let y = 31 * progress - 4
            mask.addLines([
                CGPoint(x: -2, y: -5), CGPoint(x: 26, y: -5), CGPoint(x: 26, y: y - 1),
                CGPoint(x: 10, y: y + 2), CGPoint(x: -2, y: y),
            ])
            mask.closeSubpath()
        case .read:
            // Write the two legs of the tick, then finish the border of the proof stamp.
            let drawn = min(1, progress / 0.62)
            mask.addRect(CGRect(x: 5, y: 6.5, width: 14.5 * drawn, height: 11.7))
            let radius = 12 * max(0, (progress - 0.58) / 0.42)
            mask.addRect(CGRect(x: 12 - radius, y: 12 - radius, width: 2 * radius, height: 2 * radius))
        case .calendar:
            // Print the header across, then ink the date beneath it.
            mask.addRect(CGRect(x: 0, y: 0, width: 24 * min(1, progress / 0.48), height: 10))
            let down = max(0, (progress - 0.48) / 0.52)
            mask.addRect(CGRect(x: 0, y: 10, width: 24, height: 14 * down))
        case .notebook:
            // Advance from the cloth binding across the slanted cover.
            let x = 31 * progress - 4
            mask.addLines([
                CGPoint(x: -5, y: -2), CGPoint(x: x + 1, y: -2), CGPoint(x: x - 2, y: 26), CGPoint(x: -5, y: 26),
            ])
            mask.closeSubpath()
        default:
            mask.addRect(CGRect(x: 0, y: 0, width: 24 * progress, height: 24))
        }
        return mask.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / 24, y: rect.height / 24))
    }
}
