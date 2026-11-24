import PaperReaderKit
import QuartzCore
import SwiftUI

/// A single cover texture. The window compositor moves it independently of SwiftUI layout and PDF work.
struct ShelfFlyingCover {
    let paper: Paper
    let reading: ReadingProgress
    let flight: ShelfCoverFlight
    let destination: CGRect
    let reduceMotion: Bool
    let ready: (Bool) -> Void
}

#if os(macOS)
    extension ShelfFlyingCover: NSViewRepresentable {
        func makeNSView(context: Context) -> ShelfCoverCanvas { ShelfCoverCanvas(frame: .zero) }
        func updateNSView(_ view: ShelfCoverCanvas, context: Context) {
            view.configure(self, displayScale: context.environment.displayScale)
        }
    }
    typealias ShelfCoverBaseView = NSView
#else
    extension ShelfFlyingCover: UIViewRepresentable {
        func makeUIView(context: Context) -> ShelfCoverCanvas { ShelfCoverCanvas(frame: .zero) }
        func updateUIView(_ view: ShelfCoverCanvas, context: Context) {
            view.configure(self, displayScale: context.environment.displayScale)
        }
    }
    typealias ShelfCoverBaseView = UIView
#endif

@MainActor final class ShelfCoverCanvas: ShelfCoverBaseView {
    private struct Artwork: Equatable {
        let digest: String
        let title: String
        let pageCount: Int
        let reading: ReadingProgress
        let width: CGFloat
        let scale: CGFloat
    }

    private struct Motion: Equatable {
        let flight: ShelfCoverFlight
        let destination: CGRect
        let reduced: Bool
    }

    private let book = CALayer()
    private var artwork: Artwork?
    private var motion: Motion?
    private var lastMotion: Motion?
    private var lastSize = CGSize.zero
    private var ready: ((Bool) -> Void)?
    private var reportedReady = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
            // Use an explicitly hosted, y-up layer tree. The artwork itself stays upright.
            layer = CALayer()
            wantsLayer = true
            layer?.addSublayer(book)
            setAccessibilityElement(false)
        #else
            isOpaque = false
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            layer.addSublayer(book)
        #endif
        book.shadowColor = CGColor(gray: 0, alpha: 1)
        book.shadowOpacity = 0.17
        book.shadowRadius = 10
        #if os(macOS)
            book.shadowOffset = CGSize(width: 0, height: -7)
        #else
            book.shadowOffset = CGSize(width: 0, height: 7)
        #endif
    }

    required init?(coder: NSCoder) { nil }

    #if os(macOS)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            updateMotion()
        }
    #else
        override func layoutSubviews() {
            super.layoutSubviews()
            updateMotion()
        }
    #endif

    func configure(_ input: ShelfFlyingCover, displayScale: CGFloat) {
        let width = input.flight.typesetWidth
        guard width > 0 else { return }
        if !reportedReady { ready = input.ready }
        // Keep the original line breaks and enough pixels for every panel width.
        // A resizing window moves the same layer without re-typesetting the cover at each step.
        let scale = max(1, displayScale) * max(1, ShelfCoverFlight.maximumPreviewWidth / width)
        let key = Artwork(
            digest: input.paper.digest, title: input.paper.title, pageCount: input.paper.pageCount,
            reading: input.reading, width: width, scale: scale)
        if artwork != key {
            let size = CGSize(width: width, height: width / 0.7)
            let renderer = ImageRenderer(
                content: BookCoverView(paper: input.paper, progress: input.reading)
                    .frame(width: size.width, height: size.height))
            renderer.scale = scale
            guard let image = renderer.cgImage else {
                reportReady(false)
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            book.bounds = CGRect(origin: .zero, size: size)
            book.contents = image
            book.contentsScale = scale
            book.shadowPath = CGPath(roundedRect: book.bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
            CATransaction.commit()
            artwork = key
        }
        motion = Motion(flight: input.flight, destination: input.destination, reduced: input.reduceMotion)
        updateMotion()
    }

    private func reportReady(_ success: Bool) {
        guard !reportedReady, let ready else { return }
        reportedReady = true
        self.ready = nil
        Task { @MainActor in ready(success) }
    }

    private func updateMotion() {
        guard let motion, !bounds.isEmpty, book.contents != nil, lastMotion != motion || lastSize != bounds.size else {
            return
        }
        lastSize = bounds.size
        lastMotion = motion
        let flight = motion.flight
        let now = Date.now
        let remaining = max(0, flight.endsAt.timeIntervalSince(now))
        let last = flight.pose(at: flight.awaitingLift ? now : flight.endsAt, destination: motion.destination)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        book.removeAnimation(forKey: "coverFlight")
        book.position = position(for: last)
        book.transform = transform(for: last, width: flight.typesetWidth)
        if flight.awaitingLift {
            reportReady(true)
            return
        }
        guard !motion.reduced, remaining > 1.0 / 120 else { return }

        // Core Animation interpolates these control points on the display's own refresh clock.
        let count = max(2, Int(ceil(remaining * 60)))
        let poses = (0...count).map { index in
            flight.pose(
                at: now.addingTimeInterval(remaining * Double(index) / Double(count)), destination: motion.destination)
        }
        let movement = CAKeyframeAnimation(keyPath: "position")
        movement.values = poses.map { pose in
            #if os(macOS)
                NSValue(point: position(for: pose))
            #else
                NSValue(cgPoint: position(for: pose))
            #endif
        }
        let sizing = CAKeyframeAnimation(keyPath: "transform")
        sizing.values = poses.map { NSValue(caTransform3D: transform(for: $0, width: flight.typesetWidth)) }
        movement.duration = remaining
        sizing.duration = remaining
        let group = CAAnimationGroup()
        group.animations = [movement, sizing]
        group.duration = remaining
        book.add(group, forKey: "coverFlight")
    }

    private func position(for pose: ShelfCoverPose) -> CGPoint {
        #if os(macOS)
            CGPoint(x: pose.center.x, y: bounds.height - pose.center.y)
        #else
            pose.center
        #endif
    }

    private func transform(for pose: ShelfCoverPose, width: CGFloat) -> CATransform3D {
        let scale = pose.width / width
        #if os(macOS)
            let angle = -pose.tilt
        #else
            let angle = pose.tilt
        #endif
        return CATransform3DScale(CATransform3DMakeRotation(angle * .pi / 180, 0, 0, 1), scale, scale, 1)
    }
}
