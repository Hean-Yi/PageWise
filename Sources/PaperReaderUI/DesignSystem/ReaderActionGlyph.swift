import SwiftUI

/// The arrow and dots move independently of the label, tray and button hit target.
struct ReaderActionGlyph: View {
    enum Mark { case download, more }

    let mark: Mark
    let size: CGFloat
    var receiving = false
    @Environment(\.readerIconInteraction) private var interaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var stroke = ReaderIconInteraction.idle
    @State private var revision = 0

    var body: some View {
        let pose: ReaderIconInteraction = enabled && !reduceMotion ? stroke : .idle
        return Color.clear.keyframeAnimator(initialValue: CGFloat(1), trigger: revision) { _, time in
            Canvas { context, _ in
                context.scaleBy(x: size / 20, y: size / 20)
                switch mark {
                case .download:
                    let pen = StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
                    context.stroke(Self.tray, with: .foreground, style: pen)
                    context.translateBy(x: 0, y: Self.arrowOffset(pose, time))
                    context.stroke(Self.arrow, with: .foreground, style: pen)
                case .more:
                    for index in 0..<3 {
                        let ink = Self.dotPulse(index, pose, time)
                        let pressed = pose == .pressed
                        let width = 3.5 + (pressed ? 1.6 : 0.8) * ink
                        let height = 3.5 + (pressed ? -0.55 : 0.8) * ink
                        let dot = Path(
                            ellipseIn: CGRect(
                                x: 3.3 + CGFloat(index) * 6.7 - width / 2,
                                y: 10 + (pressed ? 0.7 : -1.6) * ink - height / 2, width: width, height: height))
                        context.fill(dot, with: .foreground)
                        context.fill(dot, with: .color(ReaderTheme.accent.opacity(ink)))
                    }
                }
            }
        } keyframes: { _ in
            MoveKeyframe(CGFloat.zero)
            LinearKeyframe(CGFloat(1), duration: stroke == .hovered ? 0.64 : 0.34)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true).allowsHitTesting(false)
        .onChange(of: interaction, initial: true) { before, after in
            guard !receiving, enabled, !reduceMotion, after != .idle else { return }
            // A completed press returning to the hovered state must finish its impression.
            if after == .pressed || before != .pressed { animate(after) }
        }
        .onChange(of: receiving, initial: true) { _, started in
            if started, !reduceMotion, enabled { animate(.pressed) }
        }
    }

    private func animate(_ pose: ReaderIconInteraction) {
        stroke = pose
        revision += 1
    }

    nonisolated static func arrowOffset(_ pose: ReaderIconInteraction, _ time: CGFloat) -> CGFloat {
        switch pose {
        case .idle: return 0
        case .hovered: return -4 * pow(sin(.pi * time), 2)
        case .pressed:
            let deposit = min(time / 0.64, 1)
            let settle = max((time - 0.64) / 0.36, 0)
            return 3.8 * deposit * deposit * (3 - 2 * deposit) - 0.9 * settle * (2 - settle)
        }
    }

    nonisolated static func dotPulse(_ index: Int, _ pose: ReaderIconInteraction, _ time: CGFloat) -> CGFloat {
        guard pose != .idle else { return 0 }
        let local = min(max((time - CGFloat(index) * 0.22) / 0.56, 0), 1)
        return pow(sin(.pi * local), 2)
    }

    private nonisolated static let tray = Path { p in
        p.move(to: CGPoint(x: 2.6, y: 14.6))
        p.addLine(to: CGPoint(x: 2.6, y: 17.8))
        p.addLine(to: CGPoint(x: 17.4, y: 17.8))
        p.addLine(to: CGPoint(x: 17.4, y: 14.6))
    }
    private nonisolated static let arrow = Path { p in
        p.move(to: CGPoint(x: 10, y: 4.6))
        p.addLine(to: CGPoint(x: 10, y: 13))
        p.move(to: CGPoint(x: 6.1, y: 9.1))
        p.addLine(to: CGPoint(x: 10, y: 13))
        p.addLine(to: CGPoint(x: 13.9, y: 9.1))
    }
}

struct ReaderDownloadLabel: View {
    let title: String
    var receiving = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            ReaderActionGlyph(mark: .download, size: 14, receiving: receiving)
        }
    }
}
