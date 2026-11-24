import SwiftUI

/// The first pass lays down separate pencil strokes. On the way back the pencil fills the gaps.
struct FavoritePencilFill: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private struct Mark {
        let left: CGPoint
        let right: CGPoint
        let startsAtLeft: Bool

        func partial(_ fraction: CGFloat) -> Path {
            // The nib is wider at the start of a stroke, and its leading edge is angled.
            func edge(at position: CGFloat, side: CGFloat) -> CGPoint {
                let pressure = startsAtLeft ? 1 - position : position
                return CGPoint(
                    x: left.x + (right.x - left.x) * position + side * 0.28,
                    y: left.y + (right.y - left.y) * position + side * (0.7 + 0.25 * pressure))
            }
            let start = startsAtLeft ? 0 : 1 - fraction
            let end = startsAtLeft ? fraction : 1
            var path = Path()
            path.addLines([
                edge(at: start, side: -1), edge(at: end, side: -1),
                edge(at: end, side: 1), edge(at: start, side: 1),
            ])
            path.closeSubpath()
            return path
        }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        if progress >= 1 { return Path(rect) }

        let travel = progress * CGFloat(Self.marks.count)
        let complete = Int(travel)
        var ink = Path()
        for stamp in Self.stamps.prefix(complete) { ink.addPath(stamp) }
        let fraction = travel - CGFloat(complete)
        if fraction > 0, complete < Self.marks.count {
            ink.addPath(Self.marks[complete].partial(fraction))
        }
        return ink.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / 24, y: rect.height / 24))
    }

    private static let stamps = marks.map { $0.partial(1) }
    private static let marks: [Mark] = {
        let slope: CGFloat = 0.58
        let vertices = ReaderIcon.Glyph.starVertices
        let edges = zip(vertices, vertices.dropFirst() + vertices.prefix(1))
        let leading = (0..<9).map { 9.8 + 2.7 * CGFloat($0) }
        let returning = leading.dropLast().reversed().map { $0 + 1.35 }
        return (leading + returning).enumerated().compactMap { index, intercept in
            // Follow the actual span of each part of the star, including its long horizontal arms.
            let crossings = edges.compactMap { start, end -> CGFloat? in
                let a = start.y + slope * start.x
                let b = end.y + slope * end.x
                guard intercept >= min(a, b), intercept <= max(a, b), a != b else { return nil }
                return start.x + (end.x - start.x) * (intercept - a) / (b - a)
            }
            guard let first = crossings.min(), let last = crossings.max() else { return nil }
            let left = first - 2.4
            let right = last + 2.4
            let startsAtLeft = index.isMultiple(of: 2)
            let drift: CGFloat = startsAtLeft ? 0.13 : -0.11
            return Mark(
                left: CGPoint(x: left, y: intercept - left * slope),
                right: CGPoint(x: right, y: intercept - right * slope + drift), startsAtLeft: startsAtLeft)
        }
    }()
}
