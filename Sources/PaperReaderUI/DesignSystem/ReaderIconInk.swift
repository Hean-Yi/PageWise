import SwiftUI

/// Translation and pivot use the same 24-point grid as the drawings and SVG viewBox.
struct ReaderIconInkPose {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var degrees: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var pivotX: CGFloat = 12
    var pivotY: CGFloat = 12
}

extension ReaderIcon.Glyph {
    static let wastebasketRim: CGFloat = 9.1

    static func secondQuotationPose(for state: ReaderIconInteraction) -> ReaderIconInkPose {
        switch state {
        case .idle: return ReaderIconInkPose()
        case .hovered: return ReaderIconInkPose(x: 1.15)
        case .pressed: return ReaderIconInkPose(x: -1.2, y: -1.3)
        }
    }

    func inkPose(for state: ReaderIconInteraction) -> ReaderIconInkPose {
        let motion = Self.inkMotions[rawValue]
        var pose: ReaderIconInkPose =
            switch state {
            case .idle: ReaderIconInkPose()
            case .hovered: motion.hover
            case .pressed: motion.press
            }
        pose.pivotX = motion.pivot.x
        pose.pivotY = motion.pivot.y
        return pose
    }

    private struct InkMotion {
        let pivot: CGPoint
        let hover: ReaderIconInkPose
        let press: ReaderIconInkPose

        init(_ x: CGFloat, _ y: CGFloat, hover: ReaderIconInkPose, press: ReaderIconInkPose) {
            self.pivot = CGPoint(x: x, y: y)
            self.hover = hover
            self.press = press
        }
    }

    private static let inkMotions = allCases.map { glyph -> InkMotion in
        switch glyph {
        case .library:
            InkMotion(10, 18.5, hover: .init(y: -1.8, degrees: -10), press: .init(y: 1.35, scaleY: 0.93))
        case .read:
            InkMotion(11, 15, hover: .init(y: -2, degrees: -9), press: .init(y: 0.8, scaleX: 1.2, scaleY: 0.9))
        case .favorite:
            InkMotion(
                12, 12.6, hover: .init(y: 0.3, degrees: -12, scaleX: 1.22, scaleY: 0.83),
                press: .init(x: 0.4, degrees: 32, scaleX: 0.72, scaleY: 0.55))
        case .calendar, .notebook:
            // The date sheet and pencil move on top of a stationary binding.
            InkMotion(0, 0, hover: .init(), press: .init())
        case .paper:
            InkMotion(6.9, 7.8, hover: .init(scaleX: 1.28), press: .init(y: 4.7, scaleX: 1.32, scaleY: 0.29))
        case .source:
            InkMotion(12.4, 17.5, hover: .init(y: -0.4, degrees: -5, scaleX: 0.68), press: .init(scaleX: -0.94))
        case .export:
            InkMotion(9, 12, hover: .init(x: -1.6, scaleX: 0.94), press: .init(x: 5.6, scaleX: 0.68))
        case .citation:
            InkMotion(6, 17, hover: .init(x: -0.9, y: -1.6, degrees: -6), press: .init(x: 1.9, y: 1.4, degrees: 3))
        case .delete:
            InkMotion(
                11, 7, hover: .init(y: -1.1, degrees: -13), press: .init(x: 1, y: 6.8, degrees: 18, scaleX: 0.65))
        case .annotation:
            InkMotion(
                2.5, 21.4, hover: .init(x: 1.3, y: -0.8, degrees: -5, scaleX: 0.91, scaleY: 0.91),
                press: .init(x: 6.5, y: -0.6, degrees: -12, scaleX: 0.8, scaleY: 0.8))
        case .openNote:
            InkMotion(13, 12, hover: .init(x: -1.65, scaleX: 0.91), press: .init(x: 2.9, scaleX: 0.72))
        case .chevron:
            InkMotion(15.4, 12.1, hover: .init(x: 0.7, degrees: -9), press: .init(x: 2.4, degrees: 4))
        case .discussion:
            InkMotion(
                16, 17, hover: .init(x: -1.1, y: -1.8, degrees: -4),
                press: .init(x: -2.5, y: -3, scaleX: 1.16, scaleY: 1.14))
        case .close:
            InkMotion(12, 12, hover: .init(degrees: 8, scaleX: 1.12), press: .init(degrees: 45, scaleX: 0.85))
        case .add:
            InkMotion(12, 12, hover: .init(y: -1.3, scaleY: 0.78), press: .init(scaleX: 1.4, scaleY: 1.08))
        case .play:
            InkMotion(8, 12, hover: .init(x: 0.7, scaleY: 1.12), press: .init(x: 2, scaleX: 1.1, scaleY: 1.23))
        case .pause:
            InkMotion(16, 12, hover: .init(x: 1.5, scaleY: 1.05), press: .init(x: -3.2, scaleY: 0.92))
        }
    }
}

/// Only the engaged glyph interpolates. Its button, label and layout keep their native geometry.
struct ReaderIconLayer: Shape {
    enum Ink { case outline, spot, reversed }

    let glyph: ReaderIcon.Glyph
    let ink: Ink
    var animatableData: AnimatablePair<CGFloat, CGFloat>

    init(glyph: ReaderIcon.Glyph, ink: Ink, state: ReaderIconInteraction) {
        self.glyph = glyph
        self.ink = ink
        animatableData = AnimatablePair(state == .hovered ? 1 : 0, state == .pressed ? 1 : 0)
    }

    func path(in rect: CGRect) -> Path {
        let hover = animatableData.first
        let press = animatableData.second
        let moving = hover != 0 || press != 0
        var path = Path()
        if ink != .spot {
            path = moving ? movingOutline(hover: hover, press: press) : glyph.drawing
        }
        if ink != .outline {
            let plate = glyph.inkPlate
            var printed = moving ? plate.applying(plateTransform(hover: hover, press: press)) : plate
            if glyph == .delete && press > 0 {
                // Only the portion above the rim is visible as the paper drops inside.
                printed = printed.intersection(
                    Path(CGRect(x: 0, y: 0, width: 24, height: ReaderIcon.Glyph.wastebasketRim)))
            }
            path.addPath(printed)
        }
        return path.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / 24, y: rect.height / 24))
    }

    private func movingOutline(hover: CGFloat, press: CGFloat) -> Path {
        let outline = glyph.drawing
        switch glyph {
        case .annotation:
            let transform = plateTransform(hover: hover, press: press)
            var pen = outline.applying(transform)
            let start = CGPoint(x: 2.5, y: 21.4)
            pen.move(to: start)
            pen.addQuadCurve(to: start.applying(transform), control: CGPoint(x: 3 + 1.8 * press, y: 22.1))
            return pen
        case .citation:
            let spread = ReaderIcon.Glyph.secondQuotationPose(for: .hovered)
            let set = ReaderIcon.Glyph.secondQuotationPose(for: .pressed)
            return outline.applying(CGAffineTransform(translationX: spread.x * hover + set.x * press, y: set.y * press))
        case .openNote, .chevron:
            let advance = glyph == .openNote ? -1.65 * hover + 2.9 * press : 0.7 * hover + 2.4 * press
            var shaft = Path()
            shaft.move(to: glyph == .openNote ? CGPoint(x: 2.3, y: 9.8) : CGPoint(x: 8.6, y: 5.6))
            if glyph == .openNote { shaft.addLine(to: CGPoint(x: 2.3, y: 12.1)) }
            shaft.addLine(to: CGPoint(x: (glyph == .openNote ? 14.5 : 15.1) + advance, y: 12.1))
            return shaft
        case .close:
            let transform = CGAffineTransform(translationX: 12, y: 12)
                .rotated(by: -press * .pi / 4).translatedBy(x: -12, y: -12)
            return outline.applying(transform)
        default:
            return outline
        }
    }

    private func plateTransform(hover: CGFloat, press: CGFloat) -> CGAffineTransform {
        let lifted = glyph.inkPose(for: .hovered)
        let pressed = glyph.inkPose(for: .pressed)
        let x = lifted.x * hover + pressed.x * press
        let y = lifted.y * hover + pressed.y * press
        let degrees = lifted.degrees * hover + pressed.degrees * press
        let scaleX = 1 + (lifted.scaleX - 1) * hover + (pressed.scaleX - 1) * press
        let scaleY = 1 + (lifted.scaleY - 1) * hover + (pressed.scaleY - 1) * press
        return CGAffineTransform(translationX: x + lifted.pivotX, y: y + lifted.pivotY)
            .rotated(by: degrees * .pi / 180)
            .scaledBy(x: scaleX, y: scaleY)
            .translatedBy(x: -lifted.pivotX, y: -lifted.pivotY)
    }
}
