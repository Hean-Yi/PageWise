import SwiftUI

/// Both angles turn around the same spine, from the front cover on the right to an open spread.
struct ReflowBookPose: Equatable {
    var cover: Double
    var leaf: Double

    static let closed = Self(cover: 0, leaf: 0)
    static let open = Self(cover: 1, leaf: 0)
    private static let turned = Self(cover: 1, leaf: 1)

    private func toward(_ other: Self, progress: Double) -> Self {
        let t = min(1, max(0, progress))
        let eased = t * t * (3 - 2 * t)
        return Self(cover: cover + (other.cover - cover) * eased, leaf: leaf + (other.leaf - leaf) * eased)
    }

    static func reading(elapsed: TimeInterval, from initial: Self) -> Self {
        let cycle = 3.4
        let time = max(0, elapsed).truncatingRemainder(dividingBy: cycle)
        if time < 0.88 {
            return (elapsed < cycle ? initial : .closed).toward(.open, progress: time / 0.88)
        }
        if time < 2.12 { return open.toward(turned, progress: (time - 1.04) / 0.94) }
        return turned.toward(.closed, progress: (time - 2.12) / 0.92)
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
        let w = size.width
        let h = size.height
        // Keep the silhouette centered as the front cover swings across the spine.
        let spine = w * (0.28 + 0.22 * pose.cover)
        let top = h * 0.34
        let bottom = h * 0.88
        let ink = ReaderTheme.accent
        let pen = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
        func page(_ angle: Double, curl: Double) -> Path {
            let reach = w * 0.43 * cos(.pi * angle)
            let lift = h * 0.29 * sin(.pi * angle)
            let edge = spine + reach
            return Path { path in
                path.move(to: CGPoint(x: spine, y: top))
                path.addQuadCurve(
                    to: CGPoint(x: edge, y: top - 5 - lift),
                    control: CGPoint(x: spine + reach * 0.55, y: top - 4 - curl - lift * 0.7))
                path.addLine(to: CGPoint(x: edge, y: bottom - 5 - lift))
                path.addQuadCurve(
                    to: CGPoint(x: spine, y: bottom),
                    control: CGPoint(x: spine + reach * 0.55, y: bottom - 4 - curl - lift * 0.7))
                path.closeSubpath()
            }
        }
        let back = page(0, curl: 3 * pose.cover)
        context.stroke(back.offsetBy(dx: 0, dy: 3.5), with: .color(ink.opacity(0.6)), style: pen)
        context.fill(back, with: .color(ReaderTheme.surface))
        context.stroke(back, with: .color(ink), style: pen)
        let front = page(pose.cover, curl: 3 * pose.cover)
        context.fill(front, with: .color(ReaderTheme.elevated))
        context.stroke(front, with: .color(ink), style: pen)
        // Print on the outside of the cover narrows with it and vanishes as its inside comes into view.
        let face = max(0, cos(.pi * pose.cover))
        if face > 0.01 {
            var imprint = Path()
            let lift = h * 0.29 * sin(.pi * pose.cover)
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: spine + x * face, y: y - (5 + lift) * x / (w * 0.43))
            }
            imprint.move(to: point(4, top + 1))
            imprint.addLine(to: point(4, bottom - 1))
            for (offset, length) in [(11.0, 26.0), (15.0, 21.0)] {
                imprint.move(to: point(10, top + offset))
                imprint.addLine(to: point(length, top + offset))
            }
            context.stroke(
                imprint, with: .color(ink.opacity(face * 0.78)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        if pose.leaf > 0.001 && pose.cover - pose.leaf > 0.001 {
            let turning = page(pose.leaf, curl: 5)
            context.fill(turning, with: .color(ReaderTheme.surface))
            context.stroke(turning, with: .color(ink), style: pen)
        }
    }
}
