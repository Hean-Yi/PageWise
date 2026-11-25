import SwiftUI

/// Each angle runs from the right side of the spine (0) to the left side (1).
struct ReflowBookPose: Equatable {
    var front: Double
    var leaf: Double
    var back: Double
    var readFraction: Double

    static let closed = Self(front: 0, leaf: 0, back: 0, readFraction: 0)
    static let open = Self(front: 1, leaf: 0, back: 0, readFraction: 0)
    private static let lastPage = Self(front: 1, leaf: 1, back: 0, readFraction: 1)
    static let backCover = Self(front: 1, leaf: 1, back: 1, readFraction: 1)

    private static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }

    private func toward(_ other: Self, progress: Double) -> Self {
        let t = Self.ease(progress)
        return Self(
            front: front + (other.front - front) * t, leaf: leaf + (other.leaf - leaf) * t,
            back: back + (other.back - back) * t, readFraction: readFraction + (other.readFraction - readFraction) * t)
    }

    static func reading(elapsed: TimeInterval, from initial: Self) -> Self {
        let cycle = 9.2
        let time = max(0, elapsed).truncatingRemainder(dividingBy: cycle)
        if time < 1.12 {
            return (elapsed < cycle ? initial : .closed).toward(.open, progress: time / 0.95)
        }
        if time < 5.92 {
            let position = (time - 1.12) / 1.6
            let sheet = min(2, floor(position))
            let leaf = ease(position - sheet)
            return Self(front: 1, leaf: leaf, back: 0, readFraction: (sheet + leaf) / 3)
        }
        if time < 7.7 { return lastPage.toward(.backCover, progress: (time - 5.92) / 1.2) }
        return backCover.toward(.closed, progress: (time - 7.7) / 1.12)
    }

    func closing(elapsed: TimeInterval) -> Self {
        toward(.closed, progress: elapsed / Self.closeDuration)
    }
    static let closeDuration = 0.38
}

struct ReflowBookAnimation: View {
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var motion = Motion.still(.closed)

    private enum Playback { case idle, running, stillOpen, inactive }
    private var playback: Playback {
        if scenePhase != .active { return .inactive }
        if !running { return .idle }
        return reduceMotion ? .stillOpen : .running
    }

    private enum Motion {
        case still(ReflowBookPose)
        case reading(Date, ReflowBookPose)
        case closing(Date, ReflowBookPose)
        var isStill: Bool { if case .still = self { true } else { false } }
        func pose(at date: Date) -> ReflowBookPose {
            switch self {
            case .still(let pose): pose
            case .reading(let start, let pose): .reading(elapsed: date.timeIntervalSince(start), from: pose)
            case .closing(let start, let pose): pose.closing(elapsed: date.timeIntervalSince(start))
            }
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion.isStill)) { timeline in
            ReflowBookIllustration(pose: motion.pose(at: timeline.date))
        }
        .task(id: playback) {
            let now = Date()
            let pose = motion.pose(at: now)
            switch playback {
            case .running: motion = .reading(now, pose)
            case .stillOpen: motion = .still(.open)
            case .inactive: motion = .still(.closed)
            case .idle:
                if !reduceMotion && pose != .closed {
                    motion = .closing(now, pose)
                    do { try await Task.sleep(for: .seconds(ReflowBookPose.closeDuration)) } catch { return }
                }
                motion = .still(.closed)
            }
        }
    }
}

struct ReflowBookIllustration: View {
    let pose: ReflowBookPose

    var body: some View {
        Canvas(opaque: true) { context, size in
            // Draw on a single artboard so stroke weights, cover lettering and sheet edges scale together.
            let scale = min(size.width / 224, size.height / 168)
            guard scale > 0 else { return }
            // The covers and leaf share one presentation frame, including when an outer view is transitioning.
            context.withCGContext { drawing in
                drawing.setFillColor(ReaderTheme.canvas.resolve(in: context.environment).cgColor)
                drawing.fill(CGRect(origin: .zero, size: size))
                drawing.translateBy(x: (size.width - 224 * scale) / 2, y: (size.height - 168 * scale) / 2)
                drawing.scaleBy(x: scale, y: scale)
                draw(
                    in: drawing, ink: ReaderTheme.accent.resolve(in: context.environment).cgColor,
                    paper: ReaderTheme.surface.resolve(in: context.environment).cgColor)
            }
        }
        .transaction { $0.animation = nil }
    }

    private func draw(in drawing: CGContext, ink: CGColor, paper: CGColor) {
        let spread = min(1, (pose.front - pose.back) * 3)
        let halfWidth = 99.0
        let left = min(0, cos(.pi * pose.front))
        let right = max(0, cos(.pi * pose.back))
        let spine = 112 - halfWidth * (left + right) / 2
        let top = 23.0
        let bottom = 142.0
        drawing.setLineCap(.round)
        drawing.setLineJoin(.round)
        func stroke(_ path: Path, opacity: Double = 1, width: Double = 2.2) {
            drawing.setStrokeColor(ink)
            drawing.setAlpha(opacity)
            drawing.setLineWidth(width)
            drawing.addPath(path.cgPath)
            drawing.strokePath()
        }
        func fill(_ path: Path, color: CGColor, opacity: Double = 1) {
            drawing.setFillColor(color)
            drawing.setAlpha(opacity)
            drawing.addPath(path.cgPath)
            drawing.fillPath()
        }
        func lift(_ angle: Double) -> Double {
            (2 + 14 * spread) * sin(.pi * angle)
        }
        func page(_ angle: Double, curl: Double) -> Path {
            let face = cos(.pi * angle)
            let reach = halfWidth * face
            let rise = lift(angle)
            let edge = spine + reach
            let cornerX = 4 * face
            let cornerY = 4.0
            let flex = (curl + rise * 0.65)
            return Path { path in
                path.move(to: CGPoint(x: spine, y: top))
                path.addQuadCurve(
                    to: CGPoint(x: edge - cornerX, y: top - rise),
                    control: CGPoint(x: spine + reach * 0.52, y: top - flex))
                path.addQuadCurve(
                    to: CGPoint(x: edge, y: top - rise + cornerY), control: CGPoint(x: edge, y: top - rise))
                path.addLine(to: CGPoint(x: edge, y: bottom - rise - cornerY))
                path.addQuadCurve(
                    to: CGPoint(x: edge - cornerX, y: bottom - rise), control: CGPoint(x: edge, y: bottom - rise))
                path.addQuadCurve(
                    to: CGPoint(x: spine, y: bottom), control: CGPoint(x: spine + reach * 0.52, y: bottom - flex))
                path.closeSubpath()
            }
        }

        func cover(front: Bool) {
            let angle = front ? pose.front : pose.back
            let face = cos(.pi * angle)
            let outside = front ? face : -face
            let surface = page(angle, curl: spread * 4)
            stroke(surface.offsetBy(dx: 0, dy: 3.4), opacity: 0.5)
            fill(surface, color: paper)
            if outside > 0 {
                fill(surface, color: ink, opacity: (front ? 0.11 : 0.19) * outside)
            }
            stroke(surface)
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: spine + x * face, y: y - lift(angle) * x / halfWidth)
            }
            var print = Path()
            if outside > 0, front {
                print.move(to: point(9, top + 1.5))
                print.addLine(to: point(9, bottom - 1.5))
                for (offset, end) in [(26.0, 70.0), (34.0, 55.0)] {
                    print.move(to: point(22, top + offset))
                    print.addLine(to: point(end, top + offset))
                }
            } else if outside > 0 {
                // The press mark identifies the back even after the cover comes to rest.
                print.move(to: point(44, bottom - 15))
                print.addLine(to: point(50, bottom - 19))
                print.addLine(to: point(56, bottom - 15))
                print.addLine(to: point(50, bottom - 11))
                print.closeSubpath()
            } else {
                let stack = front ? pose.readFraction : 1 - pose.readFraction
                if stack > 0 {
                    print.move(to: point(3, bottom - 2.4 * stack))
                    print.addQuadCurve(
                        to: point(halfWidth - 4, bottom - 2.4 * stack),
                        control: point(halfWidth / 2, bottom - 3 * stack - 3))
                }
            }
            stroke(print, opacity: abs(face) * 0.78, width: 1.55)
        }

        // Once the back faces the reader it must occlude the finished pages and the front cover.
        let backFacesReader = pose.back > 0.5
        cover(front: backFacesReader)
        cover(front: !backFacesReader)
        if pose.leaf > pose.back + 0.001 && pose.front - pose.leaf > 0.001 {
            let sheet = page(pose.leaf, curl: 8 * sin(.pi * pose.leaf) + 4)
            fill(sheet, color: paper)
            stroke(sheet)
        }
        let edge = (1 - spread) * sin(.pi * pose.back)
        if edge > 0.01 {
            var binding = Path()
            binding.move(to: CGPoint(x: spine, y: top))
            binding.addLine(to: CGPoint(x: spine, y: bottom + 1))
            stroke(binding, width: 2.2 + 3 * edge)
        }
    }
}
