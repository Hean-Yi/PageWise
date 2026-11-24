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
            InkMotion(10, 18.5, hover: .init(y: -1.15, degrees: -8), press: .init(y: 0.9, degrees: 4))
        case .read:
            InkMotion(7, 12, hover: .init(degrees: -6, scaleX: 1.1), press: .init(y: 1, degrees: 5, scaleX: 0.83))
        case .favorite:
            InkMotion(
                12, 12.6, hover: .init(y: 0.3, degrees: -12, scaleX: 1.22, scaleY: 0.83),
                press: .init(x: 0.4, degrees: 32, scaleX: 0.72, scaleY: 0.55))
        case .calendar:
            InkMotion(12, 5, hover: .init(scaleY: 1.5), press: .init(y: 0.45, scaleY: 0.55))
        case .notebook:
            InkMotion(7, 12, hover: .init(x: -0.25, degrees: -3, scaleX: 1.38), press: .init(scaleX: 0.52))
        case .paper:
            InkMotion(6.9, 7.8, hover: .init(scaleX: 1.37), press: .init(y: 0.9, scaleX: 0.78, scaleY: 0.82))
        case .source:
            InkMotion(12.4, 17.5, hover: .init(degrees: -6, scaleX: 1.26), press: .init(degrees: 6, scaleX: 0.55))
        case .export:
            InkMotion(9, 12, hover: .init(x: -1.2, scaleX: 0.94), press: .init(x: 3, scaleX: 0.87))
        case .citation:
            InkMotion(6, 17, hover: .init(x: -0.65, y: -1.35, degrees: -6), press: .init(x: 1.7, y: 1, degrees: 5))
        case .delete:
            InkMotion(
                11, 7, hover: .init(y: -0.9, degrees: -10), press: .init(x: 1.2, y: 5, degrees: 12, scaleX: 0.75))
        case .annotation:
            InkMotion(16, 7, hover: .init(x: 1.1, y: -1.1, degrees: 5), press: .init(x: -1.3, y: 1.3, degrees: -3))
        case .openNote:
            InkMotion(13, 12, hover: .init(x: 1.3, scaleX: 0.93), press: .init(x: -1.5, scaleX: 0.8))
        case .chevron:
            InkMotion(15.4, 12.1, hover: .init(degrees: -12), press: .init(degrees: 12, scaleX: 0.85))
        case .discussion:
            InkMotion(15, 15, hover: .init(y: -1.4, degrees: -4), press: .init(x: -1.5, y: -2.3, scaleX: 0.85))
        case .close:
            InkMotion(12, 12, hover: .init(degrees: 10, scaleX: 1.08), press: .init(degrees: -12, scaleY: 0.8))
        case .add:
            InkMotion(12, 12, hover: .init(degrees: -6, scaleY: 1.19), press: .init(scaleY: 0.64))
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
            path = glyph.drawing
        }
        if ink != .outline {
            let plate = glyph.inkPlate
            path.addPath(moving ? plate.applying(plateTransform(hover: hover, press: press)) : plate)
        }
        return path.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / 24, y: rect.height / 24))
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
