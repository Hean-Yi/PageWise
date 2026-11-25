import SwiftUI

/// Paper and ink sit inside the glyph's 24-point grid. Only the hovered or pressed control interpolates.
struct ReaderIconPageAction: View, Animatable {
    let glyph: ReaderIcon.Glyph
    nonisolated var progress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            switch glyph {
            case .calendar: drawCalendar(in: context)
            case .notebook: drawNotebook(in: context)
            default: break
            }
        }
    }

    private static let seven = Path { path in
        path.move(to: CGPoint(x: 8, y: 12))
        path.addLine(to: CGPoint(x: 14, y: 12))
        path.addLine(to: CGPoint(x: 10.2, y: 18.2))
    }
    private static let eight = Path { path in
        path.addEllipse(in: CGRect(x: 8.9, y: 10.6, width: 5.5, height: 4.3))
        path.addEllipse(in: CGRect(x: 8.5, y: 14.9, width: 6.3, height: 4.6))
    }
    private static let thinInk = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
    private static let dateInk = StrokeStyle(lineWidth: 1.85, lineCap: .square, lineJoin: .round)

    private func drawCalendar(in context: GraphicsContext) {
        let lift = min(1, progress / 0.48)
        let tear = max(0, (progress - 0.48) / 0.52)
        if tear > 0 {
            var next = context
            next.opacity = Double(tear)
            next.stroke(Self.eight, with: .foreground, style: Self.dateInk)
        }
        var leaf = context
        leaf.opacity = Double(1 - tear)
        leaf.translateBy(x: 11.5 + 5.4 * tear, y: 14 - 4.5 * tear)
        leaf.rotate(by: .degrees(-5 * lift - 15 * tear))
        leaf.scaleBy(x: 1 + 0.12 * lift, y: 1 + 0.12 * lift)
        leaf.translateBy(x: -11.5, y: -14)
        if lift > 0 {
            let fold = 0.4 + 4 * lift
            let corner = CGPoint(x: 19.2, y: 20 - fold)
            var sheet = Path()
            sheet.addLines([
                CGPoint(x: 3.8, y: 9.5), CGPoint(x: 19.2, y: 9.5), corner,
                CGPoint(x: 19.2 - fold, y: 20), CGPoint(x: 3.8, y: 20),
            ])
            sheet.closeSubpath()
            leaf.fill(sheet, with: .color(ReaderTheme.surface))
            var edge = leaf
            edge.opacity *= Double(lift)
            edge.stroke(sheet, with: .foreground, style: Self.thinInk)
            var curl = Path()
            curl.addLines([corner, CGPoint(x: 19.2 - fold, y: 20 - fold), CGPoint(x: 19.2 - fold, y: 20)])
            leaf.stroke(curl, with: .color(ReaderTheme.accent.opacity(lift)), style: Self.thinInk)
        }
        leaf.translateBy(x: 11, y: 15)
        leaf.scaleBy(x: 1 + 0.22 * lift, y: 1 + 0.22 * lift)
        leaf.translateBy(x: -11, y: -15)
        leaf.stroke(Self.seven, with: .foreground, style: Self.dateInk)
    }

    private static let writtenLine = Path { path in
        path.move(to: CGPoint(x: 9, y: 16.3))
        path.addQuadCurve(to: CGPoint(x: 12.6, y: 14.1), control: CGPoint(x: 12.9, y: 11.9))
        path.addQuadCurve(to: CGPoint(x: 15.1, y: 15.3), control: CGPoint(x: 11.1, y: 17.8))
        path.addQuadCurve(to: CGPoint(x: 18.4, y: 14.2), control: CGPoint(x: 16.9, y: 14.3))
    }

    private static let pencil = Path { barrel in
        barrel.addLines([
            CGPoint(x: 0, y: 0), CGPoint(x: 1.2, y: -4.2), CGPoint(x: 4.4, y: -10),
            CGPoint(x: 6.5, y: -8.8), CGPoint(x: 3.3, y: -3),
        ])
        barrel.closeSubpath()
    }
    private static let point = Path { nib in
        nib.addLines([.zero, CGPoint(x: 1.2, y: -4.2), CGPoint(x: 3.3, y: -3)])
        nib.closeSubpath()
    }

    static func notebookInk(at progress: CGFloat) -> (line: Path, pencil: Path, nib: Path) {
        let turn = min(1, progress / 0.48)
        let stroke = min(1, turn * 0.72 + max(0, progress - 0.48) * 0.76)
        let line = writtenLine.trimmedPath(from: 0, to: stroke)
        let tip = line.currentPoint ?? CGPoint(x: 9, y: 16.3)
        let lift = max(0, (progress - 0.85) / 0.15)
        let pose = CGAffineTransform(translationX: tip.x - 0.8 * lift, y: tip.y - 2 * lift)
            .rotated(by: (-8 + 8 * turn - 14 * progress) * .pi / 180)
        return (line, pencil.applying(pose), point.applying(pose))
    }

    private func drawNotebook(in context: GraphicsContext) {
        let turn = min(1, progress / 0.48)
        let leaf = NotebookLeaf(progress: turn).path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        context.fill(leaf, with: .color(ReaderTheme.surface))
        context.stroke(leaf, with: .color(ReaderTheme.accent.opacity(turn)), style: Self.thinInk)
        let ink = Self.notebookInk(at: progress)
        context.stroke(ink.line, with: .foreground, style: Self.thinInk)
        context.fill(ink.pencil, with: .color(ReaderTheme.surface))
        context.stroke(ink.pencil, with: .color(ReaderTheme.accent), style: Self.thinInk)
        context.fill(ink.nib, with: .foreground)
    }
}
