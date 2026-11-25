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
            let pose = motion.pose(at: timeline.date)
            Canvas { context, size in draw(pose, in: context, size: size) }
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

    private func draw(_ pose: ReflowBookPose, in context: GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let spread = min(1, (pose.front - pose.back) * 3)
        let halfWidth = w * 0.43
        let left = min(0, cos(.pi * pose.front))
        let right = max(0, cos(.pi * pose.back))
        let spine = (w - halfWidth * (left + right)) / 2
        let top = h * 0.34
        let bottom = h * 0.88
        let ink = ReaderTheme.accent
        let outline = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
        func lift(_ angle: Double) -> Double {
            h * (0.045 + 0.235 * spread) * sin(.pi * angle)
        }
        func page(_ angle: Double, curl: Double) -> Path {
            let reach = halfWidth * cos(.pi * angle)
            let rise = lift(angle)
            return Path { path in
                path.move(to: CGPoint(x: spine, y: top))
                path.addQuadCurve(
                    to: CGPoint(x: spine + reach, y: top - 5 - rise),
                    control: CGPoint(x: spine + reach * 0.55, y: top - 4 - curl - rise * 0.7))
                path.addLine(to: CGPoint(x: spine + reach, y: bottom - 5 - rise))
                path.addQuadCurve(
                    to: CGPoint(x: spine, y: bottom),
                    control: CGPoint(x: spine + reach * 0.55, y: bottom - 4 - curl - rise * 0.7))
                path.closeSubpath()
            }
        }

        func cover(front: Bool) {
            let angle = front ? pose.front : pose.back
            let face = cos(.pi * angle)
            let outside = front ? face : -face
            let surface = page(angle, curl: spread * 3)
            context.stroke(surface.offsetBy(dx: 0, dy: 2.8), with: .color(ink.opacity(0.55)), style: outline)
            context.fill(surface, with: .color(ReaderTheme.surface))
            if outside > 0 {
                context.fill(surface, with: .color(ink.opacity((front ? 0.11 : 0.19) * outside)))
            }
            context.stroke(surface, with: .color(ink), style: outline)
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: spine + x * face, y: y - (5 + lift(angle)) * x / halfWidth)
            }
            var print = Path()
            if outside > 0, front {
                print.move(to: point(4, top + 1))
                print.addLine(to: point(4, bottom - 1))
                for (offset, length) in [(11.0, 26.0), (15.0, 21.0)] {
                    print.move(to: point(10, top + offset))
                    print.addLine(to: point(length, top + offset))
                }
            } else if outside > 0 {
                // The small press mark belongs to the back; the front carries the title rules.
                print.move(to: point(19, bottom - 6))
                print.addLine(to: point(22, bottom - 8))
                print.addLine(to: point(25, bottom - 6))
                print.addLine(to: point(22, bottom - 4))
                print.closeSubpath()
            } else {
                // Sheet edges visibly transfer from the right-hand stack to the left.
                let stack = front ? pose.readFraction : 1 - pose.readFraction
                if stack > 0 {
                    print.move(to: point(3, bottom - 1.8 * stack))
                    print.addQuadCurve(
                        to: point(halfWidth - 1, bottom - 2.6 * stack),
                        control: point(halfWidth / 2, bottom - 3 * stack - 1))
                }
            }
            context.stroke(
                print, with: .color(ink.opacity(abs(face) * 0.74)),
                style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        }

        // Once the back faces the reader it must occlude the finished pages and the front cover.
        let backFacesReader = pose.back > 0.5
        cover(front: backFacesReader)
        cover(front: !backFacesReader)
        if pose.leaf > pose.back + 0.001 && pose.front - pose.leaf > 0.001 {
            let sheet = page(pose.leaf, curl: 6 * sin(.pi * pose.leaf) + 3)
            context.fill(sheet, with: .color(ReaderTheme.surface))
            context.stroke(sheet, with: .color(ink), style: outline)
        }
        let edge = (1 - spread) * sin(.pi * pose.back)
        if edge > 0.01 {
            var binding = Path()
            binding.move(to: CGPoint(x: spine, y: top))
            binding.addLine(to: CGPoint(x: spine, y: bottom + 1))
            context.stroke(binding, with: .color(ink), style: StrokeStyle(lineWidth: 1.6 + 2.2 * edge, lineCap: .round))
        }
    }
}
