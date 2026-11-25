import SwiftUI

/// Centerlines for the printed dates. The calendar strokes these paths after scaling to keep the pen width fixed.
enum CalendarNumerals {
    private static let center = CGPoint(x: 11.7, y: 15)
    private static let days: [Path] = {
        let digits = (0...9).map(digit)
        return (1...31).map { day in
            let numbers = day < 10 ? [day] : [day / 10, day % 10]
            var date = Path()
            var x: CGFloat = 0
            for number in numbers {
                let mark = digits[number]
                let bounds = mark.boundingRect
                date.addPath(mark, transform: CGAffineTransform(translationX: x - bounds.minX, y: 0))
                x += bounds.width + 2.6
            }
            let bounds = date.boundingRect
            let widthScale: CGFloat = day < 10 ? 1.16 : 1
            return date.applying(
                CGAffineTransform(translationX: center.x, y: center.y)
                    .scaledBy(x: widthScale, y: 1)
                    .translatedBy(x: -bounds.midX, y: -bounds.midY))
        }
    }()

    static func path(day: Int, lift: CGFloat) -> Path {
        let date = days[min(31, max(1, day)) - 1]
        guard lift > 0 else { return date }
        let scale = 1 + 0.11 * min(lift, 1)
        return date.applying(
            CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -center.x, y: -center.y))
    }

    private static func digit(_ number: Int) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var mark = Path()
        switch number {
        case 0:
            mark.addEllipse(in: CGRect(x: 0, y: 0, width: 4.8, height: 7))
        case 1:
            mark.addLines([p(0, 1.5), p(2.1, 0), p(2.1, 7)])
            mark.addLines([p(0.5, 7), p(3.7, 7)])
        case 2:
            mark.move(to: p(0.1, 1.6))
            mark.addCurve(to: p(4.5, 2.2), control1: p(0.6, -0.8), control2: p(4.8, -0.5))
            mark.addQuadCurve(to: p(3.1, 4.3), control: p(4.5, 3))
            mark.addLine(to: p(0, 7))
            mark.addLine(to: p(4.8, 7))
        case 3:
            mark.move(to: p(0, 0.7))
            mark.addCurve(to: p(1.4, 3.4), control1: p(4.7, -1.4), control2: p(6.1, 3.2))
            mark.addCurve(to: p(0, 6.4), control1: p(6.6, 3.3), control2: p(4.9, 8.8))
        case 4:
            mark.addLines([p(3.7, 7), p(3.7, 0), p(0, 4.7), p(4.9, 4.7)])
        case 5:
            mark.addLines([p(4.4, 0), p(0.5, 0), p(0.2, 3.3)])
            mark.addCurve(to: p(0, 6.5), control1: p(6, 1.3), control2: p(6.2, 9.1))
        case 6:
            mark.move(to: p(3.8, 0))
            mark.addQuadCurve(to: p(0.1, 5), control: p(0.3, 0.9))
            mark.addEllipse(in: CGRect(x: 0.1, y: 3, width: 4.5, height: 4))
        case 7:
            mark.addLines([p(0, 0), p(4.8, 0), p(1.3, 7)])
        case 8:
            mark.addEllipse(in: CGRect(x: 0.4, y: 0, width: 4, height: 3.2))
            mark.addEllipse(in: CGRect(x: 0, y: 3.2, width: 4.8, height: 3.8))
        case 9:
            return digit(6).applying(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 4.8, ty: 7))
        default: break
        }
        return mark
    }
}
