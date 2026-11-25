import SwiftUI

/// Paper and ink sit inside the glyph's 24-point grid. Only the hovered or pressed control interpolates.
struct ReaderIconPageAction: View, Animatable {
    static let hoverProgress: CGFloat = 0.48
    let glyph: ReaderIcon.Glyph
    nonisolated var progress: CGFloat
    nonisolated var calendarTurns: CGFloat = 0
    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, calendarTurns) }
        set {
            progress = newValue.first
            calendarTurns = newValue.second
        }
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

    private static let thinInk = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
    private static let dateInk = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    // Inside the stationary frame, below the printed binding.
    private static let sheet = Path { path in
        path.addLines([
            CGPoint(x: 3.6, y: 9.4), CGPoint(x: 20, y: 9.4), CGPoint(x: 20, y: 15.6),
            CGPoint(x: 15.4, y: 20.4), CGPoint(x: 3.6, y: 20.4),
        ])
        path.closeSubpath()
    }
    private static let crease = Path { path in
        path.move(to: CGPoint(x: 15.8, y: 19.4))
        path.addQuadCurve(to: CGPoint(x: 19.2, y: 15.8), control: CGPoint(x: 15.6, y: 15.6))
    }
    private static let tornEdge = Path { path in
        path.addLines([
            CGPoint(x: 4.2, y: 9.7), CGPoint(x: 7, y: 9.7), CGPoint(x: 7.8, y: 10.4),
            CGPoint(x: 8.6, y: 9.7), CGPoint(x: 15.1, y: 9.7), CGPoint(x: 16, y: 10.4),
            CGPoint(x: 16.8, y: 9.7), CGPoint(x: 19.5, y: 9.7),
        ])
    }

    private func drawCalendar(in context: GraphicsContext) {
        let position = max(0, calendarTurns)
        let whole = position.rounded(.down)
        let day = (6 + Int(whole) % 31) % 31 + 1
        let fraction = position - whole
        let contact = min(1, max(0, progress))
        let lift = min(1, contact / Self.hoverProgress)
        let curl = 0.7 * lift + 0.3 * max(0, (contact - Self.hoverProgress) / (1 - Self.hoverProgress))
        func printPage(_ day: Int, in page: GraphicsContext) {
            page.stroke(CalendarNumerals.path(day: day, lift: lift), with: .foreground, style: Self.dateInk)
            page.stroke(
                Self.crease.trimmedPath(from: 0, to: curl),
                with: .color(ReaderTheme.accent.opacity(lift)), style: Self.thinInk)
        }

        var face = context
        face.clip(to: Self.sheet)
        guard fraction > 0 else {
            printPage(day, in: face)
            return
        }
        // A committed turn only travels forward. At each integer the newly uncovered sheet is the resting page.
        let peel = fraction * fraction * (3 - 2 * fraction)
        let departure = CGAffineTransform(translationX: 3.6 + 2 * peel, y: 9.4 + 15 * peel)
            .rotated(by: 0.17 * peel).translatedBy(x: -3.6, y: -9.4)
        var exposed = face
        exposed.clip(to: Self.sheet.applying(departure), options: .inverse)
        printPage(day % 31 + 1, in: exposed)

        face.concatenate(departure)
        printPage(day, in: face)
        face.opacity *= Double(sin(.pi * fraction))
        face.stroke(Self.tornEdge, with: .foreground, style: Self.thinInk)
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
        let advance = min(1, max(0, progress) / hoverProgress)
        let finish = min(1, max(0, (progress - hoverProgress) / (0.85 - hoverProgress)))
        let stroke = 0.72 * advance + 0.28 * finish
        let line = writtenLine.trimmedPath(from: 0, to: stroke)
        let tip = line.currentPoint ?? CGPoint(x: 9, y: 16.3)
        let lift = max(0, (progress - 0.85) / 0.15)
        let pose = CGAffineTransform(translationX: tip.x - 0.8 * lift, y: tip.y - 2 * lift)
            .rotated(by: (-8 + 8 * advance - 14 * progress) * .pi / 180)
        return (line, pencil.applying(pose), point.applying(pose))
    }

    private func drawNotebook(in context: GraphicsContext) {
        let ink = Self.notebookInk(at: progress)
        context.stroke(ink.line, with: .foreground, style: Self.thinInk)
        context.fill(ink.pencil, with: .color(ReaderTheme.surface))
        context.stroke(ink.pencil, with: .color(ReaderTheme.accent), style: Self.thinInk)
        context.fill(ink.nib, with: .foreground)
    }
}
