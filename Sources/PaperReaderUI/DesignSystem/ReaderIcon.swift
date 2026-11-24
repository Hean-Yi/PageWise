import SwiftUI

/// Two printing plates on a shared 24-point grid. The outline follows the control's ink.
struct ReaderIcon: View {
    enum Glyph: Int, CaseIterable {
        case library, read, favorite, calendar, notebook, paper, source
        case export, citation, delete, annotation, openNote, chevron, discussion, close, add
    }

    let glyph: Glyph
    var filled: Bool
    @ScaledMetric private var size: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.backgroundProminence) private var backgroundProminence
    @Environment(\.readerIconInteraction) private var interaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ glyph: Glyph, size: CGFloat = 16, filled: Bool = false) {
        self.glyph = glyph
        self.filled = filled
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        let state = enabled && !reduceMotion ? interaction : .idle
        ZStack {
            if glyph == .favorite {
                // The first two strokes offer a small preview. A click continues the same pencil line.
                FavoritePencilFill(progress: filled ? 1 : state == .idle ? 0 : 0.14)
                    .fill(plateStyle)
                    .animation(reduceMotion ? nil : .easeInOut(duration: filled ? 0.58 : 0.25), value: filled)
                    .mask {
                        ReaderIconLayer(glyph: .favorite, ink: .reversed, state: state)
                            .fill(style: FillStyle(eoFill: true))
                    }
                ReaderIconLayer(glyph: .favorite, ink: .spot, state: state)
                    .fill(plateStyle).opacity(!filled && state != .idle ? 1 : 0)
            } else {
                ReaderIconLayer(glyph: glyph, ink: filled ? .reversed : .spot, state: state)
                    .fill(filled ? AnyShapeStyle(.foreground) : plateStyle, style: FillStyle(eoFill: filled))
            }
            ReaderIconLayer(glyph: glyph, ink: .outline, state: state)
                .stroke(style: StrokeStyle(lineWidth: 1.7 * size / 24, lineCap: .square, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .animation(
            reduceMotion ? nil : state == .pressed ? .easeOut(duration: 0.085) : .smooth(duration: 0.24),
            value: state
        )
        .accessibilityHidden(true)
    }

    private var plateStyle: AnyShapeStyle {
        if !enabled { return AnyShapeStyle(.foreground.opacity(0.5)) }
        if backgroundProminence == .increased { return AnyShapeStyle(.foreground) }
        return AnyShapeStyle(ReaderTheme.accent)
    }
}

extension Label where Title == Text, Icon == ReaderIcon {
    @MainActor init(_ title: LocalizedStringKey, readerIcon: ReaderIcon.Glyph, size: CGFloat = 16) {
        self.init {
            Text(title)
        } icon: {
            ReaderIcon(readerIcon, size: size)
        }
    }
}

extension ReaderIcon.Glyph {
    var drawing: Path { Self.artwork[rawValue].outline }
    var inkPlate: Path { Self.artwork[rawValue].spot }

    private struct Artwork {
        var outline = Path()
        var spot = Path()
    }

    // Keep the original paths for both the Web and native renderers. Scrolling only scales them.
    private static let artwork = allCases.map { $0.engrave() }

    private func engrave() -> Artwork {
        var art = Artwork()
        switch self {
        case .library:
            // One cloth spine interrupts the row of upright and leaning volumes.
            art.outline.line([(2, 18.5), (2, 6), (6, 6), (6, 18.5)])
            art.spot.line([(8, 3), (13, 2), (13, 18.5), (8, 18.5)], closed: true)
            art.outline.line([(14.7, 6.1), (18.5, 5.2), (21.4, 18), (17.7, 18.9)], closed: true)
            art.outline.line([(1.8, 21), (22, 21)])
        case .read:
            // A clipped proof stamp and the broad downstroke of an editor's tick.
            art.outline.line(
                [
                    (3.3, 7.5), (7.7, 3.4), (18.5, 3.4), (20.7, 6.3), (20.7, 16.5),
                    (16.3, 20.6), (5.5, 20.6), (3.3, 17.7),
                ], closed: true)
            art.spot.line(
                [
                    (5.9, 11.4), (8.8, 10), (11.1, 13.2), (17.6, 6.9),
                    (19, 8.2), (10.9, 17.7),
                ], closed: true)
        case .favorite:
            // Optically even points around two open shoulders; the outline also clips the pencil.
            art.outline.addLines(Self.starVertices)
            art.outline.closeSubpath()
            // A small second plate below the crown becomes a paper cut in the solid star.
            art.spot.line([(12, 5.8), (13.8, 10.1), (16.9, 10.6), (12, 12.6)], closed: true)
        case .calendar:
            // A tear-off date sheet with a printed top band and a single oversized numeral.
            art.spot.line([(3, 5), (20.6, 5), (20.6, 9.3), (3, 9.3)], closed: true)
            art.outline.line([(3, 5), (20.6, 5), (20.6, 15.9), (15.7, 21), (3, 21)], closed: true)
            art.outline.line([(7.3, 2.5), (7.3, 6.4)])
            art.outline.line([(16.3, 2.5), (16.3, 6.4)])
            art.outline.line([(7.2, 12), (12.7, 12), (9.6, 17.5)])
        case .notebook:
            // Cloth quarter binding and the exposed edge of the page block.
            art.outline.line(
                [
                    (3.3, 5.4), (16.9, 2.5), (20.6, 4.5), (20.6, 18.7),
                    (7, 21.5), (3.3, 19.5),
                ], closed: true)
            art.spot.line([(3.3, 5.4), (7, 7.3), (7, 21.5), (3.3, 19.5)], closed: true)
            art.outline.line([(3.6, 5.5), (7, 7.3), (20.3, 4.6)])
            art.outline.line([(9.5, 11), (16.7, 9.6)])
        case .paper:
            // A front page with a broad masthead and a cropped top corner.
            art.outline.line([(4.2, 2.7), (16.1, 2.7), (20, 6.7), (20, 21.2), (4.2, 21.2)], closed: true)
            art.spot.line([(6.9, 5.8), (14.2, 5.8), (14.2, 9.8), (6.9, 9.8)], closed: true)
            art.outline.line([(7.2, 13.3), (16.7, 13.3)])
            art.outline.line([(7.2, 17), (12.8, 17)])
        case .source:
            // The raised leaf reveals the second spread beneath it.
            art.outline.line(
                [
                    (2.2, 5), (6.7, 5), (11.4, 7.4), (11.4, 20),
                    (6.7, 17.8), (2.2, 17.8),
                ], closed: true)
            art.outline.line([(11.4, 20), (17.2, 17.5), (21.6, 17.5), (21.6, 5.6), (19.5, 5.6)])
            art.spot.line([(12.4, 7.4), (18.4, 2.3), (18.4, 14.9), (12.4, 19.3)], closed: true)
        case .export:
            // A solid transfer arrow enters a bound ledger through its open edge.
            art.outline.line([
                (7.5, 7), (7.5, 4), (18.4, 2.8), (20.9, 4.7), (20.9, 20),
                (9.8, 21.3), (7.5, 19.4), (7.5, 17.3),
            ])
            art.outline.line([(18, 5.7), (18, 17.7), (9.6, 18.7)])
            art.spot.line(
                [
                    (1.6, 10.9), (9, 10.9), (8.5, 6.7), (15.4, 12.1),
                    (8.5, 17.6), (9, 13.5), (1.6, 13.5),
                ], closed: true)
        case .citation:
            // Oversized opening quotation marks, one in each ink.
            art.spot = Self.quotationMark
            art.outline = Self.quotationMark.applying(CGAffineTransform(translationX: 10, y: 0))
        case .delete:
            // A loose sheet falling into the open mouth of a wastepaper basket.
            art.spot.line([(5, 5), (13, 1.6), (16.8, 7.4), (7, 7.4)], closed: true)
            art.outline.line([(3.1, 9.1), (21, 9.1)])
            art.outline.line([(4.6, 9.3), (7.1, 20.8), (17, 20.8), (19.5, 9.3)])
            art.outline.line([(9.3, 12.6), (10.1, 17.4)])
            art.outline.line([(14.8, 12.6), (14, 17.4)])
        case .annotation:
            art.outline.line(
                [
                    (2.5, 21.4), (5.3, 11.2), (13.1, 6.2), (17.9, 10.9),
                    (12.9, 18.7),
                ], closed: true)
            art.outline.line([(3.3, 20.5), (9.6, 14.2)])
            art.spot.line([(14, 4.9), (17.5, 1.5), (22.2, 6.1), (18.7, 9.6)], closed: true)
        case .openNote:
            // A turned-back triangle at the tip of a printer's continuation arrow.
            art.outline.line([(2.3, 9.8), (2.3, 12.1), (14.5, 12.1)])
            art.spot.line([(11.9, 4.6), (22.2, 12.1), (11.9, 19.6), (15.4, 12.1)], closed: true)
        case .chevron:
            art.outline.line([(8.6, 5.6), (15.1, 12.1)])
            art.spot.line([(15.5, 10.9), (17.1, 12.3), (8.3, 19.5), (10.1, 15)], closed: true)
        case .discussion:
            art.outline.line(
                [
                    (2.3, 3.5), (18.8, 3.5), (18.8, 12.5), (9.1, 12.5),
                    (5, 16.3), (5, 12.5), (2.3, 12.5),
                ], closed: true)
            art.outline.line([(5.7, 7.9), (13.6, 7.9)])
            art.spot.line([(10.8, 15), (21.6, 15), (21.6, 22.1), (17.9, 19.4), (10.8, 19.4)], closed: true)
        case .close:
            art.outline.line([(6.7, 6.7), (17.3, 17.3)])
            art.spot.line([(16.8, 5.8), (18.2, 7.2), (7.2, 18.2), (5.8, 16.8)], closed: true)
        case .add:
            art.outline.line([(4, 12), (20, 12)])
            art.spot.line([(11, 3.3), (13, 3.3), (13, 20.7), (11, 20.7)], closed: true)
        }
        return art
    }

    static let starVertices: [CGPoint] = [
        CGPoint(x: 12, y: 2.5), CGPoint(x: 15, y: 8.55), CGPoint(x: 21.9, y: 9.6),
        CGPoint(x: 16.9, y: 14.45), CGPoint(x: 18.1, y: 21.25), CGPoint(x: 12, y: 18.05),
        CGPoint(x: 5.9, y: 21.25), CGPoint(x: 7.1, y: 14.45), CGPoint(x: 2.1, y: 9.6), CGPoint(x: 9, y: 8.55),
    ]

    private static let quotationMark = Path { path in
        path.move(to: CGPoint(x: 9.8, y: 4))
        path.addQuadCurve(to: CGPoint(x: 5.7, y: 11.6), control: CGPoint(x: 6.1, y: 8.5))
        path.line(to: [(10.2, 11.6), (9.6, 18.4), (2.8, 18.4), (3.2, 12)])
        path.addQuadCurve(to: CGPoint(x: 9.8, y: 4), control: CGPoint(x: 3.6, y: 6.9))
        path.closeSubpath()
    }
}

extension Path {
    fileprivate mutating func line(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
        guard let (x, y) = points.first else { return }
        move(to: CGPoint(x: x, y: y))
        line(to: points.dropFirst())
        if closed { closeSubpath() }
    }

    fileprivate mutating func line(to points: some Sequence<(CGFloat, CGFloat)>) {
        for (x, y) in points { addLine(to: CGPoint(x: x, y: y)) }
    }
}
